{- | The store's schema and its versions. 'check' reads a file's header before
anything writes to it: its @application_id@ says it is this kernel's store,
its @user_version@ how many 'migrations' it applied. A file is new when both
are 0 and it holds no schema object. 'migrate' applies the rest, each once, in
order, under @BEGIN IMMEDIATE@.
-}
module Effects.Store.Migration (
    OpenRefusal (..),
    Foreign (..),
    applicationId,
    latest,
    check,
    migrate,
) where

import Control.Exception (catch, throwIO)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Database.SQLite.Simple (
    Connection,
    Only (..),
    SQLError (..),
    query_,
    withImmediateTransaction,
 )
import Database.SQLite.Simple qualified as Simple
import Database.SQLite3 (Error (ErrorNotADatabase), exec)

{- | Why a file is not opened as the store: it is another application's, or
no SQLite database at all, or a newer kernel's schema. Nothing is written to
it first.
-}
data OpenRefusal
    = NotAStateStore FilePath Foreign
    | -- | The file's schema version, and the latest this kernel knows.
      NewerSchema FilePath Int Int
    deriving stock (Eq, Show)

data Foreign = ApplicationId Int64 | NotSQLite
    deriving stock (Eq, Show)

-- | The bytes @KRNL@: the first migration sets it, and open refuses a file without it.
applicationId :: Int64
applicationId = 1263685196

-- | The schema version this kernel writes: the count of its migrations.
latest :: Int
latest = length migrations

{- | How many migrations the file at this path applied (0 when it is new),
or why it is not opened. Reads only.
-}
check :: FilePath -> Connection -> IO (Either OpenRefusal Int)
check path conn = catch (verdict <$> header) notADatabase
  where
    header =
        (,,)
            <$> pragma "PRAGMA application_id"
            <*> pragma "PRAGMA user_version"
            <*> pragma "SELECT count(*) FROM sqlite_schema"
    verdict = \case
        (0, 0, 0) -> Right 0
        (app, applied, _)
            | app /= applicationId -> Left (NotAStateStore path (ApplicationId app))
            | fromIntegral applied > latest -> Left (NewerSchema path (fromIntegral applied) latest)
            | otherwise -> Right (fromIntegral applied)
    notADatabase = \case
        SQLError {sqlError = ErrorNotADatabase} -> pure (Left (NotAStateStore path NotSQLite))
        e -> throwIO e
    pragma q =
        query_ conn q >>= \case
            [Only (v :: Int64)] -> pure v
            _ -> throwIO (userError (show q <> " returned no single row"))

{- | Brings the schema to 'latest' from this many applied, read again under
the write lock first: another process may have migrated, or made the file
another application's, meanwhile.
-}
migrate :: FilePath -> Connection -> Int -> IO (Either OpenRefusal ())
migrate path conn = \case
    applied | applied == latest -> pure (Right ())
    _ -> withImmediateTransaction conn $ do
        check path conn >>= traverse (\applied -> for_ (drop applied (zip [1 :: Int ..] migrations)) apply)
  where
    apply (n, script) = do
        exec (Simple.connectionHandle conn) script
        -- A pragma takes no bound parameter; n is a number this module made.
        exec (Simple.connectionHandle conn) ("PRAGMA user_version = " <> Text.pack (show n))

{- | The migrations, oldest first, each one script; never edit one that
shipped.

1. The kernel-v2 store: @runs@, @events@ and @blobs@, append-only, as issue
   #552's Appendix A has them, and the application id.
-}
migrations :: [Text]
migrations =
    [ Text.unlines ddl <> "PRAGMA application_id = " <> Text.pack (show applicationId) <> ";\n"
    ]

-- | Appendix A's DDL, verbatim: the one source of the schema.
ddl :: [Text]
ddl =
    [ "-- The kernel's run store, file kernel-v2.db. SQLite 3.45.0 or newer."
    , "-- This file is the one source of the schema: the diagrams and the issue text come from it."
    , "--"
    , "-- Set once, by the first migration:"
    , "--   PRAGMA application_id = 1263685196;  -- the bytes 'KRNL': open refuses a file without it"
    , "--   PRAGMA user_version = 1;             -- the count of applied migrations"
    , "-- Set on every connection:"
    , "--   PRAGMA busy_timeout = 5000;"
    , "--   PRAGMA journal_mode = WAL;"
    , "--   PRAGMA synchronous = FULL;"
    , "--   PRAGMA foreign_keys = ON;"
    , "--   PRAGMA recursive_triggers = ON;      -- without it INSERT OR REPLACE skips the delete triggers"
    , "-- Every write runs inside BEGIN IMMEDIATE."
    , ""
    , "CREATE TABLE runs ("
    , "  -- One row per run. A write-once index of the run's first event (started),"
    , "  -- inserted in that event's transaction. Never updated, never deleted."
    , ""
    , "  -- The run's id, as state init made it. An event prints as <id>:<seq>, so an id holds no colon."
    , "  id            TEXT NOT NULL PRIMARY KEY"
    , "                CONSTRAINT runs_id_format CHECK (id <> '' AND instr(id, ':') = 0),"
    , "  -- The run that started this one. Optional: a top-level run has no parent."
    , "  parent_run_id TEXT REFERENCES runs (id)"
    , "                CONSTRAINT runs_parent_run_id_not_self CHECK (parent_run_id IS NOT id),"
    , "  -- The flow the run follows: engineer, 10x, architect or chief today."
    , "  -- Open text on purpose: a CHECK here could never change. The codec is its one parser."
    , "  flow          TEXT NOT NULL,"
    , "  -- The directory that holds the run's notes, as given to state init. The store finds a run by it."
    , "  notes_dir     TEXT NOT NULL,"
    , "  -- The time of the started event: the kernel's clock at append."
    , "  -- RFC 3339 profile: UTC, uppercase T and Z, exactly 3 fraction digits. Text order is time order."
    , "  created_at    TEXT NOT NULL"
    , "                CONSTRAINT runs_created_at_format CHECK ("
    , "                  length(created_at) = 24"
    , "                  AND created_at IS strftime('%Y-%m-%dT%H:%M:%fZ', created_at, '+0 seconds'))"
    , ") STRICT;"
    , ""
    , "CREATE INDEX runs_parent_run_id_idx ON runs (parent_run_id);"
    , "CREATE INDEX runs_notes_dir_idx ON runs (notes_dir);"
    , ""
    , "CREATE TABLE events ("
    , "  -- The log: one row per event, append-only. The only truth."
    , "  -- Every table below blobs is rebuilt from these rows."
    , ""
    , "  -- The order of appends across all runs. SQLite sets it: the writer never does."
    , "  -- The event-store word is global_position."
    , "  position       INTEGER PRIMARY KEY,"
    , "  -- The run this event belongs to. CloudEvents source."
    , "  run_id         TEXT    NOT NULL REFERENCES runs (id),"
    , "  -- The event's place inside its run: dense from 1, checked by the writer."
    , "  -- CloudEvents sequence. The event's id is <run_id>:<seq>."
    , "  seq            INTEGER NOT NULL"
    , "                 CONSTRAINT events_seq_positive CHECK (seq >= 1),"
    , "  -- The version of this event type's payload, from 1. A change of shape bumps it."
    , "  schema_version INTEGER NOT NULL"
    , "                 CONSTRAINT events_schema_version_positive CHECK (schema_version >= 1),"
    , "  -- What happened. CloudEvents type: a fixed name such as asked, or <step>.<outcome>."
    , "  -- Open text on purpose: flows add steps, and a CHECK here could never change."
    , "  type           TEXT    NOT NULL"
    , "                 CONSTRAINT events_type_not_empty CHECK (type <> ''),"
    , "  -- CloudEvents time: the kernel's clock at append, for every event."
    , "  -- RFC 3339 profile: UTC, uppercase T and Z, exactly 3 fraction digits. Text order is time order."
    , "  time           TEXT    NOT NULL"
    , "                 CONSTRAINT events_time_format CHECK ("
    , "                   length(time) = 24"
    , "                   AND time IS strftime('%Y-%m-%dT%H:%M:%fZ', time, '+0 seconds')),"
    , "  -- The harness session that wrote the event. Optional: a plain shell has no session."
    , "  session_id     TEXT"
    , "                 CONSTRAINT events_session_id_not_empty CHECK (session_id IS NOT ''),"
    , "  -- The commit the worktree was at. Optional: a repo with no commit yet has none."
    , "  -- A git object id: 40 (SHA-1) or 64 (SHA-256) lowercase hex."
    , "  head_sha       TEXT"
    , "                 CONSTRAINT events_head_sha_format CHECK ("
    , "                   head_sha IS NULL"
    , "                   OR (length(head_sha) IN (40, 64) AND head_sha NOT GLOB '*[^0-9a-f]*')),"
    , "  -- The dedupe key of an event a hook wrote: FNV-1a 64, 16 lowercase hex, zero padded."
    , "  -- NULL means a CLI line. A hook that fires twice appends once."
    , "  hook_digest    TEXT"
    , "                 CONSTRAINT events_hook_digest_format CHECK ("
    , "                   hook_digest IS NULL"
    , "                   OR (length(hook_digest) = 16 AND hook_digest NOT GLOB '*[^0-9a-f]*')),"
    , "  -- CloudEvents data: the payload, one JSON object (I-JSON). Its keys depend on type."
    , "  -- A union inside it carries one tag key, kind."
    , "  data           TEXT    NOT NULL"
    , "                 CONSTRAINT events_data_json_object CHECK (json_valid(data) AND json_type(data) = 'object'),"
    , "  UNIQUE (run_id, seq),"
    , "  UNIQUE (run_id, hook_digest)"
    , ") STRICT;"
    , ""
    , "CREATE INDEX events_type_idx ON events (type);"
    , "CREATE INDEX events_session_id_idx ON events (session_id);"
    , ""
    , "CREATE TABLE blobs ("
    , "  -- The content of registered files, stored once per content. Append-only."
    , "  -- An artifact event names a file by path and sha256. The file's bytes live here"
    , "  -- when the writer snapshots them (files up to 1048576 bytes; the cap lives in the writer)."
    , ""
    , "  -- SHA-256 of content: 64 lowercase hex. The OCI digest without its sha256: prefix."
    , "  sha256     TEXT    NOT NULL PRIMARY KEY"
    , "             CONSTRAINT blobs_sha256_format CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),"
    , "  -- The length of content in bytes. OCI size. Kept beside content for the OCI mapping."
    , "  size_bytes INTEGER NOT NULL,"
    , "  -- The file's bytes, as read once at registration. OCI data."
    , "  content    BLOB    NOT NULL,"
    , "  CONSTRAINT blobs_size_bytes_matches_content CHECK (size_bytes = length(content))"
    , ") STRICT;"
    , ""
    , "-- Append-only: a correction is a new event, never a changed row."
    , "-- INSERT OR REPLACE deletes the old row first. The delete triggers stop it"
    , "-- only when PRAGMA recursive_triggers = ON."
    , "CREATE TRIGGER runs_no_update BEFORE UPDATE ON runs"
    , "BEGIN SELECT RAISE(ABORT, 'runs is append-only: a run never changes'); END;"
    , "CREATE TRIGGER runs_no_delete BEFORE DELETE ON runs"
    , "BEGIN SELECT RAISE(ABORT, 'runs is append-only: a run is never deleted'); END;"
    , "CREATE TRIGGER events_no_update BEFORE UPDATE ON events"
    , "BEGIN SELECT RAISE(ABORT, 'events is append-only: log a new event'); END;"
    , "CREATE TRIGGER events_no_delete BEFORE DELETE ON events"
    , "BEGIN SELECT RAISE(ABORT, 'events is append-only: void a line with state void'); END;"
    , "CREATE TRIGGER blobs_no_update BEFORE UPDATE ON blobs"
    , "BEGIN SELECT RAISE(ABORT, 'blobs is append-only: new content is a new row'); END;"
    , "CREATE TRIGGER blobs_no_delete BEFORE DELETE ON blobs"
    , "BEGIN SELECT RAISE(ABORT, 'blobs is append-only: content is never deleted'); END;"
    ]
