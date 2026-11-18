{- | The kernel's store: one SQLite database per machine user, holding every
run and its events. The only module that speaks SQL.

Every connection waits up to 5s for another writer, runs in WAL mode, so
readers never block the writer, and enforces foreign keys. Every write runs
in an immediate transaction (@BEGIN IMMEDIATE@): a read-decide-append takes
the write lock before it reads, so two processes never number an event alike.

The schema is versioned by @PRAGMA user_version@: 'migrations' is the ordered
list, the version the count applied. A new table is a new migration.
-}
module Effects.Store (
    Store,
    Durability (..),
    withStore,
    exists,
    firstEvent,
    locked,
    misnumbered,
    children,
) where

import Control.Exception (throwIO)
import Data.Foldable (for_)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple (Connection, Only (..), Query (..), execute, executeMany, execute_, query, query_, withConnection, withImmediateTransaction)
import State.Role (flowText)
import State.Run.Codec (LogError, decodeLines, encodeLine)
import State.Run.Event (Envelope (..), Event (..), Parent (..), Principal (..), RunId, Start (..), parseRunId, runIdText)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

-- | An open store: one connection, its pragmas set and its schema current.
newtype Store = Store Connection

{- | Whether a commit waits for the disk. 'Full' survives an OS crash or a
power loss. 'Unsynced' never fsyncs: a crashed process still loses nothing
committed, but an OS crash can drop writes or corrupt the store. It saves
~4ms a writing process, the checkpoint each last connection's close syncs,
so only the test suite's throwaway stores take it.
-}
data Durability = Full | Unsynced
    deriving stock (Eq, Show)

{- | The store at this path, created with its directory if absent, open for
one action.
-}
withStore :: Durability -> FilePath -> (Store -> IO a) -> IO a
withStore durability path act = do
    createDirectoryIfMissing True (takeDirectory path)
    withConnection path $ \conn -> do
        -- The wait first: switching to WAL takes a lock another writer may hold.
        execute_ conn "PRAGMA busy_timeout = 5000"
        execute_ conn "PRAGMA journal_mode = WAL"
        execute_ conn "PRAGMA foreign_keys = ON"
        execute_ conn (synchronous durability)
        migrate conn
        act (Store conn)
  where
    synchronous = \case
        Full -> "PRAGMA synchronous = FULL"
        Unsynced -> "PRAGMA synchronous = OFF"

-- | Whether the run was started in the store.
exists :: Store -> RunId -> IO Bool
exists (Store conn) run = not . null <$> (query conn "SELECT 1 FROM runs WHERE id = ?" (Only (runIdText run)) :: IO [Only Int])

-- | The run's first event, as stored, if it has one.
firstEvent :: Store -> RunId -> IO (Maybe Text)
firstEvent (Store conn) run = fmap fromOnly . listToMaybe <$> query conn "SELECT json FROM events WHERE run = ? AND seq = 1" (Only (runIdText run))

{- | The run's events, in seq order, under the write lock for one decision:
@decide@ gets them all, or the first it cannot read, and returns the events
to append. A batch that starts the run (seq 1, @started@) adds its @runs@ row
first, in the same transaction: its flow, notes and parent come from the
start. Any other batch for a run never started violates a foreign key and
throws, as does a batch whose seqs do not follow the log's ('misnumbered').
-}
locked :: Store -> RunId -> (Either LogError [Envelope] -> ([Envelope], a)) -> IO a
locked (Store conn) run decide = withImmediateTransaction conn $ do
    rows <- query conn "SELECT json FROM events WHERE run = ? ORDER BY seq" (Only (runIdText run))
    let (new, result) = decide (decodeLines (map fromOnly rows))
    for_ (misnumbered (length rows) new) (throwIO . userError)
    for_ (startOf new) $ \(envelope, start) ->
        execute
            conn
            "INSERT INTO runs (id, parent, flow, notes, created_at) VALUES (?, ?, ?, ?, ?)"
            (runIdText run, runIdText <$> parentOf start.principal, flowText start.flow, start.notes, iso8601Show envelope.ts)
    executeMany conn "INSERT INTO events (run, seq, json) VALUES (?, ?, ?)" [(runIdText run, toInteger e.seq, encodeLine e) | e <- new]
    pure result
  where
    startOf = \case
        envelope@Envelope {seq = 1, event = Started start} : _ -> Just (envelope, start)
        _ -> Nothing
    parentOf = \case
        ByUser _ -> Nothing
        ByCaller _ -> Nothing
        ByRole parent _ _ -> Just parent.run

{- | Why these events cannot follow a log of this many: seqs run densely
from 1, so a duplicate or a gap is a writer's bug. The primary key alone
refuses only the duplicate.
-}
misnumbered :: Int -> [Envelope] -> Maybe String
misnumbered logged new = case [(envelope.seq, next) | (envelope, next) <- zip new [fromIntegral logged + 1 ..], envelope.seq /= next] of
    [] -> Nothing
    (got, next) : _ -> Just ("seq " <> show got <> " where " <> show next <> " is next: a log's seqs run densely from 1")

{- | The runs started as children of this one, oldest first: in the order
their starts were written, the rowid's, as two in one second tie on
@created_at@, whose text drops trailing zeros and so does not sort as time.
-}
children :: Store -> RunId -> IO [RunId]
children (Store conn) parent =
    query conn "SELECT id FROM runs WHERE parent = ? ORDER BY rowid" (Only (runIdText parent))
        >>= traverse (\(Only raw) -> maybe (throwIO (userError ("the store holds a run id that does not parse: " <> Text.unpack raw))) pure (parseRunId raw))

-- | Brings the schema to the last migration, each one applied once, in order.
migrate :: Connection -> IO ()
migrate conn =
    -- Read without the write lock first: a current schema, the common case, takes none.
    userVersion >>= \current -> case compare current latest of
        EQ -> pure ()
        GT -> throwIO (userError ("the kernel store's schema is version " <> show current <> ", newer than this state's " <> show latest))
        LT -> withImmediateTransaction conn $ do
            -- Again under the lock: another process may have migrated meanwhile.
            applied <- userVersion
            for_ (drop applied (zip [1 :: Int ..] migrations)) $ \(n, statements) -> do
                mapM_ (execute_ conn) statements
                -- A pragma takes no bound parameter; n is a number this module made.
                execute_ conn (Query ("PRAGMA user_version = " <> Text.pack (show n)))
  where
    latest = length migrations
    userVersion =
        query_ conn "PRAGMA user_version" >>= \case
            [Only v] -> pure v
            _ -> throwIO (userError "PRAGMA user_version returned no single row")

{- | The schema's migrations, oldest first; never edit one that shipped.

1. @runs@ holds a run's immutable facts from its start; whether it is live,
   finished or stopped is derived by replaying its events. @events@ is
   append-only, each row the event's whole envelope as "State.Run.Codec"
   encodes it; @at@ and @kind@ are generated from it for queries, so they
   cannot drift from it.
-}
migrations :: [[Query]]
migrations =
    [
        [ "CREATE TABLE runs (\
          \ id TEXT PRIMARY KEY,\
          \ parent TEXT REFERENCES runs (id),\
          \ flow TEXT NOT NULL,\
          \ notes TEXT NOT NULL,\
          \ created_at TEXT NOT NULL\
          \) STRICT"
        , "CREATE INDEX runs_parent ON runs (parent)"
        , "CREATE TABLE events (\
          \ run TEXT NOT NULL REFERENCES runs (id),\
          \ seq INTEGER NOT NULL,\
          \ json TEXT NOT NULL,\
          \ at TEXT GENERATED ALWAYS AS (json_extract(json, '$.ts')) VIRTUAL NOT NULL,\
          \ kind TEXT GENERATED ALWAYS AS (json_extract(json, '$.type')) VIRTUAL NOT NULL,\
          \ PRIMARY KEY (run, seq)\
          \) STRICT"
        ]
    ]
