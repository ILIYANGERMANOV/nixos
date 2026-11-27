{- | The fixed reports of @state report@ (#552 s9, D11, D12): each one
SELECT on the read-only connection ("Effects.Store.Sql"), its columns the
body's table. A filter keeps rows at or after a time, by the row's own
time, and of one run. Stored times are the store's fixed-width UTC text, so
text order is time order and @col >= ?@ compares times. Rows come in run
order, then by time or id.

Only the waits report's rest time is computed outside SQL, by
"Data.Report", from visits and spans read back here.
-}
module Effects.Store.Report (
    Filter (..),
    runs,
    steps,
    signals,
    gaps,
    waits,
) where

import Control.Exception (throwIO)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as Lazy
import Data.Int (Int64)
import Data.Report (SpanTime (..), Visit (..), rests, restsJson)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Tsv (Result)
import Database.SQLite.Simple (Connection, NamedParam ((:=)), queryNamed)
import Database.SQLite3 (SQLData (..))
import Effects.Store.Sql (ReadOnly, select)

{- | The rows a report keeps: at or after this time, as the store spells
times, and of this run, each when given.
-}
data Filter = Filter {since :: Maybe Text, run :: Maybe Text}
    deriving stock (Eq, Show)

{- | One row per run, its status from the projections and its counts over
the log and them. A gap is open when its status is one of these spellings:
the caller passes the one open-gap rule (ruling 1a136e0a:2.9). @--since@ is
by the run's last event.
-}
runs :: [Text] -> ReadOnly -> Filter -> IO Result
runs open ro window =
    fixed
        ro
        [ "WITH last (run_id, last_event_at, event_count) AS ("
        , "  SELECT run_id, max(time), count(*) FROM events GROUP BY run_id)"
        , "SELECT"
        , "  runs.id AS run_id,"
        , "  runs.parent_run_id,"
        , "  runs.flow,"
        , "  run_states.status,"
        , "  runs.created_at,"
        , "  last.last_event_at,"
        , "  (SELECT count(*) FROM v_sessions WHERE v_sessions.run_id = runs.id) AS session_count,"
        , "  last.event_count,"
        , "  (SELECT count(*) FROM spans WHERE spans.run_id = runs.id) AS span_count,"
        , "  (SELECT sum(input_tokens) FROM spans WHERE spans.run_id = runs.id) AS input_tokens,"
        , "  (SELECT sum(output_tokens) FROM spans WHERE spans.run_id = runs.id) AS output_tokens,"
        , "  (SELECT count(*) FROM gaps WHERE gaps.run_id = runs.id"
        , "     AND gaps.status IN (SELECT value FROM json_each(?3))) AS open_gap_count,"
        , "  (SELECT count(*) FROM v_signals WHERE v_signals.run_id = runs.id) AS signal_count"
        , "FROM runs"
        , "JOIN last ON last.run_id = runs.id"
        , "LEFT JOIN run_states ON run_states.run_id = runs.id"
        , "WHERE (?1 IS NULL OR last.last_event_at >= ?1) AND (?2 IS NULL OR runs.id = ?2)"
        , "ORDER BY runs.id"
        ]
        (bound window <> [SQLText (decodeUtf8 (Lazy.toStrict (encode open)))])

-- | The columns of @v_steps@, by the visit's entry.
steps :: ReadOnly -> Filter -> IO Result
steps ro window =
    fixed
        ro
        [ "SELECT * FROM v_steps"
        , "WHERE (?1 IS NULL OR entered_at >= ?1) AND (?2 IS NULL OR run_id = ?2)"
        , "ORDER BY run_id, step_visit_id"
        ]
        (bound window)

-- | The columns of @v_signals@, by the signal's time.
signals :: ReadOnly -> Filter -> IO Result
signals ro window =
    fixed
        ro
        [ "SELECT * FROM v_signals"
        , "WHERE (?1 IS NULL OR time >= ?1) AND (?2 IS NULL OR run_id = ?2)"
        , "ORDER BY run_id, seq"
        ]
        (bound window)

-- | One row per gap, named @<run_id>:<id>@, by the time of its @gap@ line.
gaps :: ReadOnly -> Filter -> IO Result
gaps ro window =
    fixed
        ro
        [ "SELECT"
        , "  gaps.run_id || ':' || gaps.id AS gap,"
        , "  gaps.kind,"
        , "  gaps.severity,"
        , "  gaps.area,"
        , "  gaps.status,"
        , "  gaps.fix_pr_url,"
        , "  gaps.wont_fix_reason,"
        , "  gaps.reporter_role,"
        , "  gaps.text"
        , "FROM gaps"
        , "JOIN events ON events.run_id = gaps.run_id AND events.seq = gaps.id"
        , "WHERE (?1 IS NULL OR events.time >= ?1) AND (?2 IS NULL OR gaps.run_id = ?2)"
        , "ORDER BY gaps.run_id, gaps.id"
        ]
        (bound window)

{- | One row per run and step over its visits, by their entry: how many,
their length and agent time summed (open visits count, but have neither),
and the rest time, which only the left visits have. The rest comes from
"Data.Report" over visits and spans read on the store's connection, bound
as JSON, so SQLite spells its seconds as it spells the others.
-}
waits :: Connection -> ReadOnly -> Filter -> IO Result
waits conn ro window = do
    visits <-
        map (\(runId, step, entered, left) -> Visit {runId, step, entered, left})
            <$> queryNamed
                conn
                "SELECT run_id, step, CAST(round(unixepoch(entered_at, 'subsec') * 1000) AS INTEGER), CAST(round(unixepoch(left_at, 'subsec') * 1000) AS INTEGER) FROM step_visits WHERE left_at IS NOT NULL AND (:since IS NULL OR entered_at >= :since) AND (:run IS NULL OR run_id = :run)"
                [":since" := window.since, ":run" := window.run]
    spans <-
        map (\(runId, started, ended) -> SpanTime {runId, started, ended})
            <$> ( queryNamed
                    conn
                    "SELECT run_id, CAST(round(unixepoch(started_at, 'subsec') * 1000) AS INTEGER), CAST(round(unixepoch(ended_at, 'subsec') * 1000) AS INTEGER) FROM spans WHERE :run IS NULL OR run_id = :run"
                    [":run" := window.run] ::
                    IO [(Text, Int64, Maybe Int64)]
                )
    fixed
        ro
        [ "SELECT"
        , "  run_id,"
        , "  step,"
        , "  count(*) AS visit_count,"
        , "  sum(duration_seconds) AS duration_seconds,"
        , "  sum(agent_seconds) AS agent_seconds,"
        , "  (SELECT value ->> 2 FROM json_each(?3)"
        , "     WHERE value ->> 0 = v_steps.run_id AND value ->> 1 = v_steps.step) / 1000.0 AS rest_seconds"
        , "FROM v_steps"
        , "WHERE (?1 IS NULL OR entered_at >= ?1) AND (?2 IS NULL OR run_id = ?2)"
        , "GROUP BY run_id, step"
        , "ORDER BY run_id, min(step_visit_id)"
        ]
        (bound window <> [SQLText (restsJson (rests visits spans))])

-- | The filter's parameters, @?1@ and @?2@.
bound :: Filter -> [SQLData]
bound window = [maybe SQLNull SQLText window.since, maybe SQLNull SQLText window.run]

-- | A report's statement: fixed text, so a guard refusing it is a bug.
fixed :: ReadOnly -> [Text] -> [SQLData] -> IO Result
fixed ro statement params =
    select ro (Text.unlines statement) params
        >>= either (throwIO . userError . ("a report's SQL was refused: " <>) . show) pure
