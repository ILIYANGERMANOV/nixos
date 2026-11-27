{- | One row of @runs@, flat as SQL holds it: a write-once index of a run's
first event, built from it by "Data.Payload.Event". Beside it the table's
DDL, its append-only triggers and its row's 'Insert'.
-}
module Data.Entity.Run (RunRow (..), table, triggers, runInsert) where

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

data RunRow = RunRow
    { id :: Text
    , parentRunId :: Maybe Text
    , flow :: Text
    , notesDir :: Text
    , createdAt :: Text
    }
    deriving stock (Eq, Show)

table :: Table
table =
    indexed ["notes_dir"] . indexed ["parent_run_id"] $
        strictTable
            "runs"
            [ "  -- One row per run. A write-once index of the run's first event (started),"
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
            ]

triggers :: [Text]
triggers = appendOnly table "a run never changes" "a run is never deleted"

runInsert :: RunRow -> Insert
runInsert row =
    Insert
        "runs"
        Abort
        ( ("id", SqlText row.id)
            :| [ ("parent_run_id", nullable SqlText row.parentRunId)
               , ("flow", SqlText row.flow)
               , ("notes_dir", SqlText row.notesDir)
               , ("created_at", SqlText row.createdAt)
               ]
        )
