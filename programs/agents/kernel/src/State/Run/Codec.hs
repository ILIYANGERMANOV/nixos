{- | The CLI's and the hand-back protocol's spellings of the run's events:
an event's type, a stop on the wire, a task's state as @state record task@
names it, the task and breakdown files, and a span's token counts, which the
hooks and the log spell alike. The log's payload is "Data.Payload.Event"'s.
-}
module State.Run.Codec (
    eventType,
    areaText,
    reasonText,
    handoverReasonText,
    stopToken,
    stopWire,
    parseStopLine,
    judgementText,
    flowText,
    waitingText,
    tokenWordText,
    tokenWordName,
    shaText,
    urlText,
    taskIdText,
    branchText,
    repoText,
    taskStateName,
    taskStateKind,
    taskStateArgs,
    prStates,
    topicText,
    decodeBreakdown,
    decodeTask,
    ijsonNatural,
    instructionKindText,
    usageData,
    usageOf,
) where

import Data.Aeson (Object, (.:?), (.=))
import Data.Aeson.Types (Parser, Series)

import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import State.Category.Step (eventText)
import State.Role (flowText)
import State.Run.Event (
    EpicMove (..),
    Event (..),
    HandoverReason (..),
    InstructionKind (..),
    Stop (..),
    StopReason (..),
    TaskState (..),
    TokenWord (..),
    Url,
    Usage (..),
    Waiting (..),
    tookEvent,
 )
import State.Run.Gap (Closure (..), GapMove (..))
import State.Run.IJson (maxIJsonInteger)
import State.Step.Artifact (
    areaText,
    branchText,
    decodeBreakdown,
    decodeTask,
    judgementText,
    repoText,
    shaText,
    taskIdText,
    topicText,
    urlText,
 )

eventType :: Event -> Text
eventType = \case
    Started _ -> "started"
    Targeted _ -> "target"
    Extended _ -> "extend"
    Gapped _ -> "gap"
    Took scope outcome -> eventText (tookEvent scope outcome)
    Stopped _ -> "stop"
    Overridden _ _ -> "overridden"
    Refused _ -> "refused"
    Asked _ -> "asked"
    RetaggedSecurity _ -> "retagged"
    RuledOn _ _ -> "ruled"
    Forwarded _ _ -> "forwarded"
    Answered {} -> "answered"
    QuestionParked _ _ -> "parked"
    Spawning _ _ -> "spawning"
    Spawned _ -> "spawned"
    Resumed {} -> "resumed"
    HandedBack {} -> "handed_back"
    TaskMoved _ _ -> "task"
    Held _ _ -> "held"
    ActedOn _ _ -> "acted"
    TaskAdded _ _ -> "task_added"
    Restarted -> "restarted"
    WorkerHandedBack _ _ -> "worker_handed_back"
    WorkerSpawned _ _ -> "worker_spawned"
    WorkerReturned _ _ -> "worker_returned"
    AgentEnded _ -> "agent_ended"
    Suspended _ _ -> "suspended"
    Focused _ -> "focused"
    Voided _ _ -> "voided"
    WorktreeMoved _ _ -> "worktree_moved"
    ArtifactLogged {} -> "artifact"
    Noted _ _ -> "note"
    HandedOver _ -> "handover"
    SessionStarted _ -> "session_started"
    GapMoved _ move -> case move of
        Propose _ -> "gap_fix_proposed"
        Close (Fixed _) -> "gap_fixed"
        Close (WontFix _) -> "gap_wont_fix"
    SpanStarted _ -> "span_started"
    SpanEnded {} -> "span_ended"
    EpicMoved _ move -> case move of
        Opens _ _ -> "epic_opened"
        Readies _ -> "epic_ready"
        Merges -> "epic_merged"
    TaskHead _ _ -> "task_head"
    TaskBaseChanged {} -> "task_base_changed"
    Instructed _ _ -> "instructed"
    UserNeeded _ -> "user_needed"
    UserNeededDone _ _ -> "user_needed_done"
    StopgapSet {} -> "stopgap_set"
    StopgapUnset _ _ -> "stopgap_unset"

-- | An instruction's kind, as @state record instructed@ and the log spell it.
instructionKindText :: InstructionKind -> Text
instructionKindText = \case
    GoalInstruction -> "goal"
    ScopeInstruction -> "scope"
    RuleInstruction -> "rule"
    PermissionInstruction -> "permission"

-- | A hand-back token as line 1 opens with it, on the wire (#360).
tokenWordText :: TokenWord -> Text
tokenWordText = \case
    ReadyWord -> "READY"
    NeedsDecisionWord -> "NEEDS_DECISION"
    AwaitWord -> "AWAIT"
    BlockedWord -> "BLOCKED"
    FailedWord -> "FAILED"

-- | A hand-back token as the log and @state resume@ spell it: its wire word in lowercase.
tokenWordName :: TokenWord -> Text
tokenWordName = Text.toLower . tokenWordText

-- | A hand-over's reason, as the log and the CLI spell it.
handoverReasonText :: HandoverReason -> Text
handoverReasonText = \case
    Context -> "context"
    User -> "user"
    Crash -> "crash"

{- | A stop on the wire (#360): its hand-back token, and the prefix its why
takes there: the hand-back's spelling of a stop. The log's is
"Data.Payload.Event"'s @reason@ and @detail@.
-}
stopToken :: StopReason -> (Text, Text)
stopToken = \case
    Blocked -> ("BLOCKED", "")
    Failed -> ("FAILED", "")
    Replan -> ("NEEDS_DECISION", "plan wrong: ")
    OutOfRounds -> ("BLOCKED", "out of rounds: ")

-- | A stop's hand-back token and its payload.
stopWire :: Stop -> (Text, Text)
stopWire stop = (word, prefix <> stop.why)
  where
    (word, prefix) = stopToken stop.reason

-- | The stop a hand-back's line 1 says, if it says one.
parseStopLine :: Text -> Maybe Stop
parseStopLine line = parseStop word (Text.drop 1 payload)
  where
    (word, payload) = Text.breakOn " " line

{- | The prefixed reasons are tried first, so @BLOCKED out of rounds: x@ reads as
'OutOfRounds', as the wire cannot tell it from a 'Blocked' whose why says so.
-}
parseStop :: Text -> Text -> Maybe Stop
parseStop token payload =
    listToMaybe
        [ Stop reason why
        | reason <- sortOn (Text.null . snd . stopToken) [minBound .. maxBound]
        , let (word, prefix) = stopToken reason
        , word == token
        , Just why <- [Text.stripPrefix prefix payload]
        ]

-- | The states that name their PR, by the name 'taskStateName' gives each: @state record task@'s.
prStates :: [(Text, Url -> TaskState)]
prStates =
    [ ("ci", InCi)
    , ("review", InReview)
    , ("merged", Merged)
    , ("kept", Kept)
    , ("round", Round)
    , ("delivered", Delivered)
    ]

-- | As @state record task@ names it.
taskStateName :: TaskState -> Text
taskStateName = \case
    InCi _ -> "ci"
    InReview _ -> "review"
    Merged _ -> "merged"
    Kept _ -> "kept"
    Round _ -> "round"
    Parked _ _ -> "parked"
    Delivered _ -> "delivered"

{- | A task state as its status (#552's Appendix B section F) and the log's
@kind@ spell it; @state record task@'s name is 'taskStateName'.
-}
taskStateKind :: TaskState -> Text
taskStateKind = \case
    InCi _ -> "in_ci"
    InReview _ -> "in_review"
    Merged _ -> "merged"
    Kept _ -> "kept"
    Round _ -> "round"
    Parked _ _ -> "parked"
    Delivered _ -> "delivered"

-- | The arguments @state record task@ takes after the task's id for this state.
taskStateArgs :: TaskState -> Text
taskStateArgs moved =
    Text.unwords $
        taskStateName moved : case moved of
            InCi pr -> [urlText pr]
            InReview pr -> [urlText pr]
            Merged pr -> [urlText pr]
            Kept pr -> [urlText pr]
            Round pr -> [urlText pr]
            Parked why pr -> why : maybe [] (\url -> ["--pr", urlText url]) pr
            Delivered pr -> [urlText pr]

-- | #360's @AWAIT <what> <refs>@: what a run hands up to be waited on.
waitingText :: Waiting -> Text
waitingText = \case
    Ci -> "ci"
    Merge -> "merge"

reasonText :: StopReason -> Text
reasonText = \case
    Blocked -> "blocked"
    Failed -> "failed"
    Replan -> "replan"
    OutOfRounds -> "rounds"

{- | An I-JSON integer (RFC 7493 s2.2): under 2^53, so every JSON reader
reads it exactly. One at or above does not fit, so its row reads as
'Unknown'. The bound is sound for a voided seq: @appendTo@
("State.Run.Fold") logs a void only of a seq the run already logged, and no
run logs 2^53 events.
-}
ijsonNatural :: Natural -> Parser Natural
ijsonNatural n
    | toInteger n <= maxIJsonInteger = pure n
    | otherwise = fail (show n <> " is no I-JSON integer: it is 2^53 or more")

-- | A span's token counts, GenAI's @gen_ai.usage.*@: a count not reported is left out, never 0.
usageData :: Usage -> Series
usageData usage =
    foldMap ("input_tokens" .=) usage.inputTokens
        <> foldMap ("output_tokens" .=) usage.outputTokens
        <> foldMap ("cache_read_input_tokens" .=) usage.cacheReadTokens
        <> foldMap ("cache_write_input_tokens" .=) usage.cacheWriteTokens

{- | A span's token counts from the hook's @usage@ or the log's payload: a
count left out is not reported; one that is no I-JSON integer is refused.
-}
usageOf :: Object -> Parser Usage
usageOf obj =
    Usage
        <$> count "input_tokens"
        <*> count "output_tokens"
        <*> count "cache_read_input_tokens"
        <*> count "cache_write_input_tokens"
  where
    count key = obj .:? key >>= traverse ijsonNatural
