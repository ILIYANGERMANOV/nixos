{- | The CLI's and the hand-back protocol's spellings of the run's events:
an event's type, a stop on the wire, a task's state as @state record task@
names it, and the task and breakdown files. The log's payload is
"Data.Payload.Event"'s.
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
    shaText,
    urlText,
    taskIdText,
    branchText,
    repoText,
    taskStateName,
    taskStateArgs,
    prStates,
    topicText,
    decodeBreakdown,
    decodeTask,
) where

import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Step (eventText)
import State.Role (flowText)
import State.Run.Event (
    Event (..),
    HandoverReason (..),
    Stop (..),
    StopReason (..),
    TaskState (..),
    Url,
    Waiting (..),
    tookEvent,
 )
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
    Spawning _ -> "spawning"
    Spawned _ -> "spawned"
    Resumed _ -> "resumed"
    HandedBack _ _ -> "handed_back"
    TaskMoved _ _ -> "task"
    Held _ _ -> "held"
    ActedOn _ _ -> "acted"
    TaskAdded _ -> "task_added"
    Restarted -> "restarted"
    WorkerHandedBack _ _ -> "worker_handed_back"
    WorkerSpawned _ _ -> "worker_spawned"
    WorkerReturned _ _ -> "worker_returned"
    AgentEnded _ -> "agent_ended"
    Suspended _ _ -> "suspended"
    Focused _ -> "focused"
    Voided _ _ -> "voided"
    WorktreeMoved _ _ -> "worktree_moved"
    ArtifactLogged _ _ -> "artifact"
    Noted _ _ -> "note"
    HandedOver _ -> "handover"
    SessionStarted _ -> "session_started"

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
