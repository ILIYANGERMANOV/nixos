{- | One row of @events@, flat as SQL holds it: text and integers, a 'Maybe'
for each nullable column. @position@ is SQLite's, never read or written.
What a row means is "Data.Payload.Event"'s. Beside it the table's DDL, its
append-only triggers and its row's 'Insert'.
-}
module Data.Entity.Event (EventRow (..), table, triggers, eventInsert) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Table (
    Insert (..),
    OnConflict (..),
    Table,
    Value (..),
    appendOnly,
    indexed,
    nullable,
    strictTable,
 )
import Data.Text (Text)

data EventRow = EventRow
    { runId :: Text
    , seq :: Int64
    , schemaVersion :: Int64
    , eventType :: Text
    -- ^ The column @type@.
    , time :: Text
    , sessionId :: Maybe Text
    , headSha :: Maybe Text
    , hookDigest :: Maybe Text
    , payload :: Text
    -- ^ The column @data@: one JSON object.
    }
    deriving stock (Eq, Show)

table :: Table
table =
    indexed ["session_id"] . indexed ["type"] $
        strictTable
            "events"
            [ "  -- The log: one row per event, append-only. The only truth."
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
            ]

triggers :: [Text]
triggers =
    appendOnly table "log a new event" "void a line with state void"

eventInsert :: EventRow -> Insert
eventInsert row =
    Insert
        "events"
        Abort
        ( ("run_id", SqlText row.runId)
            :| [ ("seq", SqlInteger row.seq)
               , ("schema_version", SqlInteger row.schemaVersion)
               , ("type", SqlText row.eventType)
               , ("time", SqlText row.time)
               , ("session_id", nullable SqlText row.sessionId)
               , ("head_sha", nullable SqlText row.headSha)
               , ("hook_digest", nullable SqlText row.hookDigest)
               , ("data", SqlText row.payload)
               ]
        )
