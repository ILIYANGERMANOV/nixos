{- | The store's runs and events, read and appended as rows. Every write runs
in an immediate transaction (@BEGIN IMMEDIATE@): a read-decide-append takes
the write lock before it reads, so two processes never number an event alike.
Each row's column order lives here, beside its SQL.
-}
module Effects.Store.Events (
    Write (..),
    exists,
    rows,
    locked,
    misnumbered,
    children,
    inNotes,
) where

import Control.Exception (throwIO)
import Data.Entity.Event (EventRow (..))
import Data.Entity.Run (RunRow (..))
import Data.Foldable (for_, toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Database.SQLite.Simple (
    Connection,
    Only (..),
    Query,
    execute,
    executeMany,
    query,
    withImmediateTransaction,
 )
import Effects.Store.Connection (Store (..))

{- | What a decision appends: events to a started run, or a run's start, its
@runs@ row with its first events. A @runs@ row without its event 1 is no
write.
-}
data Write = Append (NonEmpty EventRow) | Start RunRow (NonEmpty EventRow)
    deriving stock (Eq, Show)

-- | Whether the run was started in the store.
exists :: Store -> Text -> IO Bool
exists (Store conn) run =
    not . null
        <$> (query conn "SELECT 1 FROM runs WHERE id = ?" (Only run) :: IO [Only Int])

-- | The run's rows, in seq order, read in one statement, without the write lock.
rows :: Store -> Text -> IO [EventRow]
rows (Store conn) = selectRows conn

{- | The run's rows, in seq order, under the write lock for one decision:
@decide@ gets them all and returns what to write. Events for a run never
started violate a foreign key and throw, as do events whose seqs do not
follow the log's ('misnumbered').
-}
locked :: Store -> Text -> ([EventRow] -> (Maybe Write, a)) -> IO a
locked (Store conn) run decide = withImmediateTransaction conn $ do
    logged <- selectRows conn run
    let (write, result) = decide logged
    for_ write $ \case
        Append new -> append (length logged) new
        Start start new -> do
            execute
                conn
                "INSERT INTO runs (id, parent_run_id, flow, notes_dir, created_at) VALUES (?, ?, ?, ?, ?)"
                (start.id, start.parentRunId, start.flow, start.notesDir, start.createdAt)
            append (length logged) new
    pure result
  where
    append count new = do
        for_ (misnumbered count new) (throwIO . userError)
        executeMany
            conn
            "INSERT INTO events (run_id, seq, schema_version, type, time, session_id, head_sha, hook_digest, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
            [ ( row.runId
              , row.seq
              , row.schemaVersion
              , row.eventType
              , row.time
              , row.sessionId
              , row.headSha
              , row.hookDigest
              , row.payload
              )
            | row <- toList new
            ]

selectRows :: Connection -> Text -> IO [EventRow]
selectRows conn run =
    map eventRow
        <$> query
            conn
            "SELECT run_id, seq, schema_version, type, time, session_id, head_sha, hook_digest, data FROM events WHERE run_id = ? ORDER BY seq"
            (Only run)
  where
    eventRow
        ( runId
            , n
            , schemaVersion
            , eventType
            , time
            , sessionId
            , headSha
            , hookDigest
            , payload
            ) =
            EventRow
                { runId
                , seq = n
                , schemaVersion
                , eventType
                , time
                , sessionId
                , headSha
                , hookDigest
                , payload
                }

{- | Why these rows cannot follow a log of this many: seqs run densely from
1, so a duplicate or a gap is a writer's bug. The unique key alone refuses
only the duplicate.
-}
misnumbered :: Int -> NonEmpty EventRow -> Maybe String
misnumbered count new = case [ (row.seq, next)
                             | (row, next) <- zip (toList new) [fromIntegral count + 1 ..]
                             , row.seq /= next
                             ] of
    [] -> Nothing
    (got, next) : _ ->
        Just
            ( "seq "
                <> show got
                <> " where "
                <> show next
                <> " is next: a log's seqs run densely from 1"
            )

{- | The runs started as children of this one, oldest first: in the order
their starts were written, the rowid's, as two in one millisecond tie on
@created_at@.
-}
children :: Store -> Text -> IO [Text]
children (Store conn) =
    ids conn "SELECT id FROM runs WHERE parent_run_id = ? ORDER BY rowid"

-- | The runs started in this notes dir, oldest first, as 'children' orders them.
inNotes :: Store -> Text -> IO [Text]
inNotes (Store conn) =
    ids conn "SELECT id FROM runs WHERE notes_dir = ? ORDER BY rowid"

ids :: Connection -> Query -> Text -> IO [Text]
ids conn sql key = map fromOnly <$> query conn sql (Only key)
