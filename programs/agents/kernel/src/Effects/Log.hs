{- | A run's log, by its id: its first event and its raw rows read without
the write lock, and every write one read-decide-append under it, so two writers never number an
event alike. The real one is the kernel's run store ("Effects.Store.Events"),
which keeps rows: this module maps them to the domain and back through
"Data.Payload.Event", for the store and the test double alike.
-}
module Effects.Log (
    Log (..),
    exists,
    firstEvent,
    rows,
    locked,
    Logged (..),
    Unread (..),
    children,
    inNotes,
    runLogIO,
    Upcasts,
    shipped,
    firstOf,
    decision,
) where

import Control.Exception (throwIO)
import Data.Bifunctor (first)
import Data.Entity.Event (EventRow (..))
import Data.Int (Int64)
import Data.List (genericLength)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Payload.Event (
    Decoded (..),
    RetiredEvent (..),
    UnknownEvent (..),
    decodeRow,
    dumpLine,
    eventRow,
    runRow,
 )
import Data.Payload.Upcast (Upcasts, shipped)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (
    Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    IOE,
    liftIO,
    (:>),
 )
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Error.Static (Error, throwError)
import Effects.Environment (Environment, lookupEnv)
import Effects.Store.Connection (Durability, OpenRefusal, Store, withStore)
import Effects.Store.Events (Write (..))
import Effects.Store.Events qualified as Store
import Numeric.Natural (Natural)
import State.Protocol.Binding (runStore)
import State.Run.Event (Envelope, EventId (..), RunId, parseRunId, runIdText)

data Log :: Effect where
    Exists :: RunId -> Log m Bool
    -- | The run's first row the fold reads, decoded, without the write lock.
    FirstEvent :: RunId -> Log m (Maybe (Either Unread Envelope))
    -- | The run's rows raw, one JSON Lines line each, without the write lock.
    Rows :: RunId -> Log m [Text]
    Locked :: RunId -> (Either Unread Logged -> ([Envelope], a)) -> Log m a
    Children :: RunId -> Log m [RunId]
    InNotes :: FilePath -> Log m [RunId]

type instance DispatchOf Log = Dynamic

{- | A run's log as the fold reads it: its events, without the rows of a
retired type, whose hook ids stay seen, and the count of every row, so the
next event takes seq @rows + 1@ after a retired row too.
-}
data Logged = Logged {events :: [Envelope], seen :: Set EventId, rows :: Natural}
    deriving stock (Eq, Show)

-- | A row this state cannot read, which refuses every append to its run.
data Unread = Unread {seq :: Int64, eventType :: Text, schemaVersion :: Int64}
    deriving stock (Eq, Show)

-- | Whether the run was started.
exists :: (Log :> es) => RunId -> Eff es Bool
exists = send . Exists

-- | The run's first event, or the row it cannot read, if it was started.
firstEvent :: (Log :> es) => RunId -> Eff es (Maybe (Either Unread Envelope))
firstEvent = send . FirstEvent

{- | The run's rows as they are stored, one line each in seq order, a row of
any type or version included: none for a run never started.
-}
rows :: (Log :> es) => RunId -> Eff es [Text]
rows = send . Rows

{- | The run's log, locked for one decision: @decide@ gets the log so far,
or the first row it cannot read, and returns the events to append. The lock lasts
until they are written. Events for a run never started that do not start it
throw.
-}
locked ::
    (Log :> es) =>
    RunId -> (Either Unread Logged -> ([Envelope], a)) -> Eff es a
locked run = send . Locked run

-- | The runs started as children of this one, oldest first.
children :: (Log :> es) => RunId -> Eff es [RunId]
children = send . Children

-- | The runs started in this notes dir, oldest first.
inNotes :: (Log :> es) => FilePath -> Eff es [RunId]
inNotes = send . InNotes

{- | The log in the run store the environment names ('runStore'), opened for
each operation at this durability, its rows read through these upcasts. A
file that is not this kernel's store is an 'OpenRefusal'. A store error, such
as a lock still held after the wait, or no store at all, throws an
'IOException': an outage the shell tells.
-}
runLogIO ::
    (Environment :> es, Error OpenRefusal :> es, IOE :> es) =>
    Upcasts -> Durability -> Eff (Log : es) a -> Eff es a
runLogIO upcasts durability = interpret $ \_ op -> do
    path <- runStore <$> lookupEnv "XDG_STATE_HOME" <*> lookupEnv "HOME"
    case path of
        Nothing ->
            liftIO
                ( throwIO
                    (userError "no run store: neither XDG_STATE_HOME nor HOME is an absolute path")
                )
        Just db ->
            liftIO (withStore durability db (onStore upcasts op))
                >>= either throwError pure

onStore :: Upcasts -> Log m a -> Store -> IO a
onStore upcasts op store = case op of
    Exists run -> Store.exists store (runIdText run)
    FirstEvent run -> firstOf upcasts <$> Store.rows store (runIdText run)
    Rows run -> map dumpLine <$> Store.rows store (runIdText run)
    Locked run decide -> Store.locked store (runIdText run) (decision upcasts decide)
    Children run -> Store.children store (runIdText run) >>= runIds
    InNotes notes -> Store.inNotes store (Text.pack notes) >>= runIds

{- | The first of a run's rows the fold reads, decoded: a retired row is
skipped, as the fold skips it.
-}
firstOf :: Upcasts -> [EventRow] -> Maybe (Either Unread Envelope)
firstOf upcasts =
    listToMaybe . mapMaybe (\row -> readable row (decodeRow upcasts row))
  where
    readable row = \case
        Known e -> Just (Right e)
        Retired _ -> Nothing
        Unknown u -> Just (Left (unread row u))

-- | The row this state cannot read, named by its seq and type.
unread :: EventRow -> UnknownEvent -> Unread
unread row u =
    Unread {seq = row.seq, eventType = u.eventType, schemaVersion = u.schemaVersion}

{- | A domain decision over a run's rows: it gets the log, or the first row
that does not read, and its events become the write.
-}
decision ::
    Upcasts ->
    (Either Unread Logged -> ([Envelope], a)) ->
    [EventRow] ->
    (Maybe Write, a)
decision upcasts decide logged =
    first (fmap writeOf . nonEmpty) (decide (loggedOf upcasts logged))

loggedOf :: Upcasts -> [EventRow] -> Either Unread Logged
loggedOf upcasts logged = case [unread row u | (row, Unknown u) <- decoded] of
    bad : _ -> Left bad
    [] ->
        Right
            Logged
                { events = [e | (_, Known e) <- decoded]
                , seen =
                    Set.fromList
                        [Hashed d | (_, Retired RetiredEvent {digest = Just d}) <- decoded]
                , rows = genericLength logged
                }
  where
    decoded = [(row, decodeRow upcasts row) | row <- logged]

-- | The rows of these events: with the run's @runs@ row when they start it.
writeOf :: NonEmpty Envelope -> Write
writeOf new@(head1 :| _) = case runRow head1 of
    Just run -> Start run (fmap eventRow new)
    Nothing -> Append (fmap eventRow new)

runIds :: [Text] -> IO [RunId]
runIds =
    traverse
        ( \raw ->
            maybe
                ( throwIO
                    (userError ("the store holds a run id that does not parse: " <> Text.unpack raw))
                )
                pure
                (parseRunId raw)
        )
