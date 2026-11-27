{- | The spans projection (#552 Appendix A): one row per subagent a run's
lead spawned, from its @span_started@ line to its @span_ended@ one, as an
OpenTelemetry GenAI @invoke_agent@ span. Its times are those lines'.
-}
module Data.Projection.Spans (
    projection,
    rows,
    SpanRow (..),
    SpanEnd (..),
    spanInsert,
) where

import Control.Monad (mfilter)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Projection (
    Insert,
    Projection (..),
    Table,
    Value (..),
    insertInto,
    integer,
    nullable,
    spellings,
    strictTable,
 )
import Data.Projection.Column (runIdValue, timeValue)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Category.Flow (roleText)
import State.Run.Codec (tokenWordName)
import State.Run.Event (
    Envelope (..),
    Event (..),
    Harness (..),
    RunId,
    SpanEnding (..),
    SpanStart (..),
    Usage (..),
 )
import State.Run.Fold (RunState)
import State.Run.Id (SpanId (..))

projection :: Projection
projection =
    Projection
        { name = "spans"
        , version = 1
        , tables = spans :| []
        }

{- | Each span the trace starts, ended by the line that names it, if any:
the fold takes one end per span.
-}
rows :: NonEmpty (Envelope, RunState) -> [Insert]
rows trace =
    [ spanInsert
        ( SpanRow
            e.run
            e.seq
            start {parent = mfilter ((`Set.member` started) . (.spanSeq)) start.parent}
            e.ts
            (Map.lookup (SpanId e.seq) ends)
        )
    | e <- lines'
    , SpanStarted start <- [e.event]
    ]
  where
    lines' = map fst (toList trace)
    -- A void drops the line a span names as its parent: the row names none.
    started = Set.fromList [e.seq | e <- lines', SpanStarted _ <- [e.event]]
    ends =
        Map.fromList
            [ (ended, SpanEnd e.ts ending usage)
            | e <- lines'
            , SpanEnded ended ending usage <- [e.event]
            ]

-- | A span, by the seq of its @span_started@ line, and its end once seen.
data SpanRow = SpanRow
    { runId :: RunId
    , id :: Natural
    , start :: SpanStart
    , startedAt :: UTCTime
    , end :: Maybe SpanEnd
    }
    deriving stock (Eq, Show)

-- | How and when a span ended, and the tokens its agent's own requests used.
data SpanEnd = SpanEnd {endedAt :: UTCTime, ending :: SpanEnding, usage :: Usage}
    deriving stock (Eq, Show)

-- | OpenTelemetry's span status, as its row spells it.
data StatusCode = Ok | Error
    deriving stock (Eq, Show, Enum, Bounded)

statusCodeName :: StatusCode -> Text
statusCodeName = \case
    Ok -> "ok"
    Error -> "error"

-- | gen_ai.operation.name: a span is always an agent's invocation.
data Operation = InvokeAgent
    deriving stock (Eq, Show, Enum, Bounded)

operationName :: Operation -> Text
operationName = \case
    InvokeAgent -> "invoke_agent"

{- | The span's row. Its harness's agent id and its provider stay NULL: no
line of the log carries them (#552 s9, D7).
-}
spanInsert :: SpanRow -> Insert
spanInsert row =
    insertInto
        "spans"
        ( ("run_id", runIdValue row.runId)
            :| [ ("id", integer row.id)
               , ("parent_span_id", nullable (integer . (.spanSeq)) row.start.parent)
               , ("operation_name", SqlText (operationName InvokeAgent))
               , ("agent_role", SqlText (roleText row.start.role))
               , ("harness", SqlText harness)
               , ("harness_agent_id", SqlNull)
               , ("provider_name", SqlNull)
               , ("request_model", nullable SqlText row.start.model)
               , ("started_at", timeValue row.startedAt)
               , ("ended_at", nullable (timeValue . (.endedAt)) row.end)
               , ("status_code", nullable (SqlText . statusCodeName) status)
               , ("handback_token", nullable (SqlText . tokenWordName) token)
               , ("error_type", nullable SqlText errorType)
               , ("input_tokens", count (.inputTokens))
               , ("output_tokens", count (.outputTokens))
               , ("cache_read_input_tokens", count (.cacheReadTokens))
               , ("cache_write_input_tokens", count (.cacheWriteTokens))
               , ("brief", SqlText row.start.brief)
               , ("handback", nullable SqlText handback)
               ]
        )
  where
    Harness harness = row.start.harness
    count field = nullable integer (field . (.usage) =<< row.end)
    (status, token, errorType, handback) = case (.ending) <$> row.end of
        Nothing -> (Nothing, Nothing, Nothing, Nothing)
        Just (WithHandback word text) -> (Just Ok, Just word, Nothing, Just text)
        -- The payload's own error type for a span with no hand-back.
        Just NoHandback -> (Just Error, Nothing, Just "no_handback", Nothing)

spans :: Table
spans =
    strictTable
        "spans"
        [ "  -- One row per subagent a run's lead spawned: from its brief to its hand-back."
        , "  -- OpenTelemetry GenAI invoke_agent span. The lead itself has no span."
        , "  -- NULL in an optional column means the harness did not report it, never 0."
        , ""
        , "  -- The run. One run is one trace."
        , "  run_id                   TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the span_started event. Not an OpenTelemetry hex span id."
        , "  id                       INTEGER NOT NULL,"
        , "  -- The span of the agent that spawned this one. Optional: the lead spawned it."
        , "  parent_span_id           INTEGER,"
        , "  -- gen_ai.operation.name. Always invoke_agent."
        , "  operation_name           TEXT    NOT NULL"
        , "                           CONSTRAINT spans_operation_name_enum CHECK (operation_name IN "
            <> spellings operationName
            <> "),"
        , "  -- The subagent's role, such as researcher or fixer. gen_ai.agent.name."
        , "  agent_role               TEXT    NOT NULL,"
        , "  -- The harness that ran the agent, such as claude-code or opencode."
        , "  harness                  TEXT    NOT NULL,"
        , "  -- The id the harness gave this agent. Not unique: a continued agent keeps it in a new span."
        , "  -- Always NULL for now: no event carries it."
        , "  harness_agent_id         TEXT,"
        , "  -- gen_ai.provider.name, such as anthropic. Always NULL for now: no event carries it."
        , "  provider_name            TEXT,"
        , "  -- gen_ai.request.model: the model asked for."
        , "  request_model            TEXT,"
        , "  -- The time of the span_started event."
        , "  started_at               TEXT    NOT NULL,"
        , "  -- The time of the span_ended event. NULL: still running, or its end was never seen."
        , "  ended_at                 TEXT,"
        , "  -- ok: the agent handed back, whatever its token. A blocked or failed hand-back is ok."
        , "  -- error: it ended with no hand-back, or the harness reported an error. NULL while running."
        , "  status_code              TEXT"
        , "                           CONSTRAINT spans_status_code_enum CHECK (status_code IN "
            <> spellings statusCodeName
            <> "),"
        , "  -- The first word of the agent's hand-back. NULL while running, and when it ended with no hand-back."
        , "  handback_token           TEXT"
        , "                           CONSTRAINT spans_handback_token_enum CHECK ("
        , "                             handback_token IN "
            <> spellings tokenWordName
            <> "),"
        , "  -- error.type: what kind of error ended the span. Set only when status_code is error."
        , "  error_type               TEXT,"
        , "  -- gen_ai.usage.input_tokens: all input tokens, cached ones included."
        , "  input_tokens             INTEGER,"
        , "  -- gen_ai.usage.output_tokens."
        , "  output_tokens            INTEGER,"
        , "  -- gen_ai.usage.cache_read.input_tokens: the part of input_tokens read from a cache."
        , "  cache_read_input_tokens  INTEGER,"
        , "  -- gen_ai.usage.cache_write.input_tokens: the part of input_tokens written to a cache."
        , "  cache_write_input_tokens INTEGER,"
        , "  -- The brief the agent was given, in full."
        , "  brief                    TEXT    NOT NULL,"
        , "  -- The agent's hand-back text, in full. NULL while running, and when it ended with none."
        , "  handback                 TEXT,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),"
        , "  FOREIGN KEY (run_id, parent_span_id) REFERENCES spans (run_id, id),"
        , "  CONSTRAINT spans_parent_span_id_not_self CHECK (parent_span_id IS NOT id),"
        , "  CONSTRAINT spans_status_code_iff_ended CHECK ((status_code IS NOT NULL) = (ended_at IS NOT NULL)),"
        , "  CONSTRAINT spans_error_type_iff_error CHECK ((error_type IS NOT NULL) = (status_code IS 'error')),"
        , "  CONSTRAINT spans_handback_token_only_when_ended CHECK (handback_token IS NULL OR ended_at IS NOT NULL),"
        , "  CONSTRAINT spans_handback_only_when_ended CHECK (handback IS NULL OR ended_at IS NOT NULL)"
        ]
