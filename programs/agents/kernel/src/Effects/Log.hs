{- | A run's log, by its id: its first event read without the write lock, and
every write one read-decide-append under it, so two writers never number an
event alike. The real one is the kernel's run store ("Effects.Store.Events"),
which keeps rows: this module maps them to the domain and back through
"Data.Payload.Event", for the store and the test double alike.
-}
module Effects.Log (
    Log (..),
    exists,
    firstEvent,
    locked,
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
import Data.Entity.Event (EventRow)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import Data.Payload.Event (decodeRow, eventRow, runRow)
import Data.Payload.Upcast (Upcasts, shipped)
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
import State.Protocol.Binding (runStore)
import State.Run.Codec (LineError, LogError (..))
import State.Run.Event (Envelope, RunId, parseRunId, runIdText)

data Log :: Effect where
    Exists :: RunId -> Log m Bool
    -- | The run's first row, decoded, read without the write lock.
    FirstEvent :: RunId -> Log m (Maybe (Either LineError Envelope))
    Locked :: RunId -> (Either LogError [Envelope] -> ([Envelope], a)) -> Log m a
    Children :: RunId -> Log m [RunId]
    InNotes :: FilePath -> Log m [RunId]

type instance DispatchOf Log = Dynamic

-- | Whether the run was started.
exists :: (Log :> es) => RunId -> Eff es Bool
exists = send . Exists

-- | The run's first event, or why it does not read, if it was started.
firstEvent :: (Log :> es) => RunId -> Eff es (Maybe (Either LineError Envelope))
firstEvent = send . FirstEvent

{- | The run's log, locked for one decision: @decide@ gets every event so far,
or the first it cannot read, and returns the events to append. The lock lasts
until they are written. Events for a run never started that do not start it
throw.
-}
locked ::
    (Log :> es) =>
    RunId -> (Either LogError [Envelope] -> ([Envelope], a)) -> Eff es a
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
    Locked run decide -> Store.locked store (runIdText run) (decision upcasts decide)
    Children run -> Store.children store (runIdText run) >>= runIds
    InNotes notes -> Store.inNotes store (Text.pack notes) >>= runIds

-- | The first of a run's rows, decoded.
firstOf :: Upcasts -> [EventRow] -> Maybe (Either LineError Envelope)
firstOf upcasts = \case
    [] -> Nothing
    row : _ -> Just (decodeRow upcasts row)

{- | A domain decision over a run's rows: it gets every row decoded, or the
first that does not read, counted from 1, and its events become the write.
-}
decision ::
    Upcasts ->
    (Either LogError [Envelope] -> ([Envelope], a)) ->
    [EventRow] ->
    (Maybe Write, a)
decision upcasts decide logged =
    first (fmap writeOf . nonEmpty) (decide (traverse decoded (zip [1 ..] logged)))
  where
    decoded (n, row) = first (LogError n) (decodeRow upcasts row)

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
