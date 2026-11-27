{- | The views over the projections and the log (#552 Appendix A): the read
API an agent queries with @state sql@. Each is its @CREATE VIEW@ statement
exactly as SQLite stores it in @sqlite_schema.sql@, comments kept and no
@;@, so the open that checks the projections' DDL checks the views too, and
a changed view is made anew by the same rebuild. View text is DDL: it lives
beside the tables' DDL in "Data.Projection", and the store only runs it.
-}
module Data.Projection.Views (views) where

import Data.Text (Text)
import Data.Text qualified as Text

-- | Every view, each after the views and tables it reads.
views :: [Text]
views = [sessions, signals, steps]

statement :: [Text] -> Text
statement = Text.intercalate "\n"

sessions :: Text
sessions =
    statement
        [ "CREATE VIEW v_sessions AS"
        , "-- One row per harness session of a run, from the event envelope. Events with no session are left out."
        , "SELECT"
        , "  run_id,                               -- the run"
        , "  session_id,                           -- the harness session"
        , "  min(time) AS started_at,              -- the time of the session's first event in this run"
        , "  max(time) AS last_event_at,           -- the time of its last event in this run"
        , "  count(*) AS event_count,              -- how many events it wrote"
        , "  sum(type = 'handover') AS handover_count,  -- how many handovers it wrote"
        , "  max(CASE WHEN type = 'session_started' THEN data ->> '$.harness' END) AS harness,"
        , "                                        -- the harness, from session_started. NULL: no such event"
        , "  max(CASE WHEN type = 'session_started' THEN data ->> '$.transcript_path' END) AS transcript_path"
        , "                                        -- the session's transcript file, from session_started"
        , "FROM events"
        , "WHERE session_id IS NOT NULL"
        , "GROUP BY run_id, session_id"
        ]

signals :: Text
signals =
    statement
        [ "CREATE VIEW v_signals AS"
        , "-- Friction that the log shows by itself: one row per refusal, stop, override, void,"
        , "-- extension and stuck question. Voided lines are included."
        , "SELECT"
        , "  run_id,                               -- the run"
        , "  seq,                                  -- the event's seq"
        , "  time,                                 -- the event's time"
        , "  session_id,                           -- the session that wrote it, if any"
        , "  CASE type WHEN 'asked' THEN 'stuck' ELSE type END AS signal,"
        , "                                        -- refused, stop, overridden, voided, extend or stuck"
        , "  CASE type"
        , "    WHEN 'refused' THEN data ->> '$.code'"
        , "    WHEN 'stop' THEN data ->> '$.reason'"
        , "    WHEN 'overridden' THEN data ->> '$.to'"
        , "  END AS code,                          -- the refusal code, the stop reason or the state an override went to"
        , "  coalesce(data ->> '$.message', data ->> '$.detail', data ->> '$.reason', data ->> '$.question') AS detail"
        , "                                        -- the words that came with it"
        , "FROM events"
        , "WHERE type IN ('refused', 'stop', 'overridden', 'voided', 'extend')"
        , "   OR (type = 'asked' AND data ->> '$.question_kind' = 'stuck')"
        ]

steps :: Text
steps =
    statement
        [ "CREATE VIEW v_steps AS"
        , "-- Each step visit with its length and the agent time inside it."
        , "SELECT"
        , "  step_visits.run_id,                   -- the run"
        , "  step_visits.id AS step_visit_id,      -- the visit"
        , "  step_visits.step,                     -- the flow state"
        , "  step_visits.entered_at,               -- when the run moved in"
        , "  step_visits.left_at,                  -- when it moved on. NULL: the run is here now"
        , "  unixepoch(step_visits.left_at, 'subsec') - unixepoch(step_visits.entered_at, 'subsec') AS duration_seconds,"
        , "                                        -- the visit's length. NULL while open"
        , "  CASE WHEN step_visits.left_at IS NOT NULL THEN coalesce(("
        , "    SELECT sum("
        , "      unixepoch(min(coalesce(spans.ended_at, step_visits.left_at), step_visits.left_at), 'subsec')"
        , "      - unixepoch(max(spans.started_at, step_visits.entered_at), 'subsec'))"
        , "    FROM spans"
        , "    WHERE spans.run_id = step_visits.run_id"
        , "      AND spans.started_at < step_visits.left_at"
        , "      AND coalesce(spans.ended_at, step_visits.left_at) > step_visits.entered_at"
        , "  ), 0) END AS agent_seconds            -- span time inside the visit, summed over parallel agents:"
        , "                                        -- it can pass duration_seconds. NULL while open"
        , "FROM step_visits"
        ]
