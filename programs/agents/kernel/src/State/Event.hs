{- | One line of a run's log: what happened, and the envelope that names and
places it. A step's outcome is an 'Outcome', named by the step it ends
('outcomeEvent'), so a log is read off the flow's graph. A question is an
'Asking' and the events on its id that close it. The 10x's fan-out logs its
children ('Spawned', 'HandedBack'), the agents it sends ('Spawning',
'Resumed') and its tasks ('TaskMoved', 'Held', 'ActedOn') as stay events.
-}
module State.Event (
    Envelope (..),
    Source (..),
    EventId (..),
    eventId,
    RunId,
    parseRunId,
    runIdText,
    SessionId (..),
    Digest (..),
    Event (..),
    Start (..),
    FlowName (..),
    Principal (..),
    Parent (..),
    Op (..),
    Asking (..),
    Asker (..),
    AgentRole (..),
    roleText,
    fanRole,
    childRoles,
    Stop (..),
    StopReason (..),
    Note (..),
    Outcome (..),
    outcomeEvent,
    DraftPr (..),
    Commit (..),
    Picks (..),
    Judgement (..),
    Sha (..),
    Url (..),
    Branch (..),
    Label (..),
    Requirement (..),
    Check (..),
    StateName (..),
    TaskId (..),
    Task (..),
    Topic (..),
    Tasks,
    BreakdownError (..),
    breakdown,
    taskList,
    Child (..),
    Said (..),
    TaskState (..),
) where

import Control.Monad (foldM)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Ask (Above, OneLine, Op (..), Parent (..), Principal (..), Proposal, QId, Question)
import State.Cap (EventName, StateName (..), Step (..), continueEvent, exitEvent, skipEvent)
import State.Flow (FanEvent (Leaves), FanId (..), fanEvent, fanName)
import State.Id (Digest (..), EventId (..), RunId, TaskId (..), parseRunId, runIdText)
import State.Mode (Area, Quality, Size)

{- | The id is not stored: a CLI record's is its run and seq, so only a hook
record carries one of its own.
-}
data Envelope = Envelope
    { source :: Source
    , seq :: Natural
    , ts :: UTCTime
    , run :: RunId
    , head :: Maybe Sha
    , session :: Maybe SessionId
    , event :: Event
    }
    deriving stock (Eq, Show)

{- | Who wrote the line. A hook can fire twice for one message, so its record
is keyed on a hash of the run, agent and message, and the second is a no-op.
-}
data Source = Cli | Hook Digest
    deriving stock (Eq, Show)

eventId :: Envelope -> EventId
eventId envelope = case envelope.source of
    Cli -> Numbered envelope.run envelope.seq
    Hook digest -> Hashed digest

newtype SessionId = SessionId Text
    deriving stock (Eq, Show)

data Event
    = Started Start
    | -- | Set once.
      QualitySet Quality
    | -- | Set once; only 'Grew' changes it.
      SizeSet Size
    | -- | A Trivial task found bigger: the size is Normal from here.
      Grew Text
    | -- | A step's outcome, or a mode's skip: the one event that moves the run.
      Took Outcome
    | -- | Terminal: it ends every question still pending too.
      Stopped Stop
    | {- | A question for this run to rule on or forward: its own, or one handed
      up to it, under the id it was first asked by.
      -}
      Asked Asking
    | {- | The question is 'State.Ask.Security' from here on. The event names no
      kind, so none re-tags a question away from it (law Ceiling).
      -}
      RetaggedSecurity QId
    | -- | This run ruled on the question (law Audit).
      RuledOn QId Proposal
    | -- | This run passed the question up, to whoever started it.
      Forwarded QId Above
    | -- | The answer that came down, and who gave it.
      Answered QId Text Above
    | -- | The escape edge, outside the graph: to the named state, and why.
      Overridden StateName Text
    | -- | An event the run refused, logged so the next read can warn of it.
      Refused Note
    | -- | The 10x spawns an engineer for the task, before the child's @init@ logs 'Spawned'.
      Spawning TaskId
    | -- | A child run started for a task, at the fan-out (written by the child's @init@).
      Spawned Child
    | -- | The 10x resumes the child run, which works again until it hands back.
      Resumed RunId
    | -- | What a child run's hand-back said, by its run id.
      HandedBack RunId Said
    | -- | Where a task's PR stands, as the 10x saw it.
      TaskMoved TaskId TaskState
    | -- | A finding held back from a task's PR, at this url.
      Held TaskId Url
    | -- | The 10x acted on the task's held wake at this url: it is held no more.
      ActedOn TaskId Url
    | {- | A worker's hand-back line 1 the run triages as a question of its own
      (@state ask --from <role>@) before it goes on: a stop, or a question with no kind.
      -}
      WorkerHandedBack AgentRole OneLine
    deriving stock (Eq, Show)

{- | The run's environment is data here, read by whoever delivers advice, never
by the flow: a flow does not branch on who runs it (law Principal-blind).
-}
data Start = Start
    { flow :: FlowName
    , notes :: FilePath
    , principal :: Principal
    , interface :: Set Op
    }
    deriving stock (Eq, Show)

data FlowName = EngineerFlow | TenXFlow
    deriving stock (Eq, Show, Enum, Bounded)

-- | A question as it reached this run, and the step the run was at.
data Asking = Asking {question :: Question, step :: StateName, from :: Asker}
    deriving stock (Eq, Show)

-- | Who put the question to this run.
data Asker = Itself | Subagent AgentRole | ChildRun RunId
    deriving stock (Eq, Show)

-- | A subagent's role, as @state handback <role>@ names it: @implementer@.
newtype AgentRole = AgentRole Text
    deriving stock (Eq, Show)

roleText :: AgentRole -> Text
roleText (AgentRole role) = role

-- | The role a fan-out's children run as: an engineer runs a whole engineer flow.
fanRole :: FanId -> AgentRole
fanRole =
    AgentRole . \case
        FResearchers -> "researcher"
        FEngineers -> "engineer"

-- | The roles that run a whole flow of their own under a run's fan-out.
childRoles :: [AgentRole]
childRoles = [fanRole FEngineers]

data Stop = Stop {reason :: StopReason, why :: Text}
    deriving stock (Eq, Show)

-- | @replan@ ends this run; a new run starts at @Ctx@.
data StopReason = Blocked | Failed | Replan | Fuel | Outgrown
    deriving stock (Eq, Show, Enum, Bounded)

-- | A refusal as the reader saw it: what was wrong, and the fix.
data Note = Note {message :: Text, fix :: Text}
    deriving stock (Eq, Show)

{- | One per edge of the engineer flow, carrying what that outcome reports.
A skip is its own outcome: a skipped step stays in the path (#351).
-}
data Outcome
    = -- | The number of researchers.
      ResearchDone Natural
    | ResearchSkipped
    | InterviewEnough
    | InterviewMore
    | -- | The plan file.
      PlanDone FilePath
    | SimplifyPlanDone
    | SimplifyPlanSkipped
    | AlternativeDone
    | AlternativeSkipped
    | ConfirmConfirmed
    | ConfirmAdjusted
    | DraftDone DraftPr
    | ImplementDone Commit
    | RefactorDone Sha
    | -- | Why it was skipped.
      RefactorSkipped Text
    | ReviewClean Sha
    | ReviewRows Sha
    | PickFinal Picks
    | PickLoop Picks
    | FixDone Commit
    | DescribeDone Sha
    | SimplifyPrDone Sha
    | SimplifyPrSkipped Sha
    | AwaitCiGreen Sha
    | -- | Red has a failing check by definition.
      AwaitCiRed Sha (NonEmpty Check)
    | FixPrDone Sha
    | ReadyDone Url
    | -- | POC keeps a draft: the PR it left.
      ReadySkipped Url
    | BreakdownDone Tasks
    | -- | Every task of the fan-out is settled ("State.Fan").
      FanDone FanId
    | -- | The one PR the merge left.
      MergeDone Url
    deriving stock (Eq, Show)

-- | The graph's name for the edge an outcome takes, from "State.Cap"'s names.
outcomeEvent :: Outcome -> EventName
outcomeEvent = \case
    ResearchDone _ -> continueEvent Research
    ResearchSkipped -> skipEvent Research
    InterviewEnough -> exitEvent Interview
    InterviewMore -> continueEvent Interview
    PlanDone _ -> continueEvent PlanS
    SimplifyPlanDone -> continueEvent SimplifyP
    SimplifyPlanSkipped -> skipEvent SimplifyP
    AlternativeDone -> continueEvent Alternative
    AlternativeSkipped -> skipEvent Alternative
    ConfirmConfirmed -> exitEvent Confirm
    ConfirmAdjusted -> continueEvent Confirm
    DraftDone _ -> continueEvent Draft
    ImplementDone _ -> continueEvent Implement
    RefactorDone _ -> continueEvent Refactor
    RefactorSkipped _ -> skipEvent Refactor
    ReviewClean _ -> exitEvent Review
    ReviewRows _ -> continueEvent Review
    PickFinal _ -> exitEvent Pick
    PickLoop _ -> continueEvent Pick
    FixDone _ -> continueEvent Fix
    DescribeDone _ -> continueEvent Describe
    SimplifyPrDone _ -> continueEvent SimplifyPR
    SimplifyPrSkipped _ -> skipEvent SimplifyPR
    AwaitCiGreen _ -> exitEvent AwaitCi
    AwaitCiRed _ _ -> continueEvent AwaitCi
    FixPrDone _ -> continueEvent FixPR
    ReadyDone _ -> continueEvent Ready
    ReadySkipped _ -> skipEvent Ready
    BreakdownDone _ -> continueEvent Breakdown
    FanDone fan -> fanEvent Leaves (fanName fan)
    MergeDone _ -> continueEvent Merge

-- | The draft PR, synced from GitHub.
data DraftPr = DraftPr {url :: Url, base :: Branch, branch :: Branch}
    deriving stock (Eq, Show)

-- | A commit and the areas it touches, which decide a fix's full review.
data Commit = Commit {head :: Sha, touches :: Set Area}
    deriving stock (Eq, Show)

{- | The rows to fix, labelled so one finding keeps its label across rounds,
and the verdict on each requirement.
-}
data Picks = Picks {rows :: Set Label, verdicts :: Map Requirement Judgement}
    deriving stock (Eq, Show)

data Judgement = Met | NotMet | Unverified
    deriving stock (Eq, Show, Enum, Bounded)

newtype Sha = Sha Text
    deriving stock (Eq, Show)

newtype Url = Url Text
    deriving stock (Eq, Show)

newtype Branch = Branch Text
    deriving stock (Eq, Show)

newtype Label = Label Text
    deriving stock (Eq, Ord, Show)

newtype Requirement = Requirement Text
    deriving stock (Eq, Ord, Show)

-- | A CI check, by name.
newtype Check = Check Text
    deriving stock (Eq, Ord, Show)

-- | What the engineer run for a task is briefed with.
data Task = Task
    { id :: TaskId
    , deps :: [TaskId]
    -- ^ Tasks whose work this one builds on: earlier ones only.
    , base :: Branch
    , branch :: Branch
    , quality :: Quality
    , size :: Size
    , qa :: Bool
    , heavy :: Bool
    -- ^ At most one heavy task runs at a time.
    , security :: Set Topic
    }
    deriving stock (Eq, Show)

-- | The security-sensitive work a task's brief flags.
data Topic = CiTopic | AuthTopic | DatabaseTopic | SecretsTopic
    deriving stock (Eq, Ord, Show, Enum, Bounded)

{- | The tasks in order, ids unique, each depending on earlier tasks only, so
the dependencies are acyclic by construction. Built by 'breakdown' alone.
-}
newtype Tasks = Tasks (NonEmpty Task)
    deriving stock (Eq, Show)

data BreakdownError
    = TaskTwice TaskId
    | -- | The task names a dependency that is not an earlier task.
      DependsLater TaskId TaskId
    deriving stock (Eq, Show)

breakdown :: NonEmpty Task -> Either BreakdownError Tasks
breakdown tasks = Tasks tasks <$ foldM check [] tasks
  where
    check seen task =
        case (task.id `elem` seen, filter (`notElem` seen) task.deps) of
            (True, _) -> Left (TaskTwice task.id)
            (False, later : _) -> Left (DependsLater task.id later)
            (False, []) -> Right (task.id : seen)

taskList :: Tasks -> [Task]
taskList (Tasks tasks) = toList tasks

-- | A child run of the fan-out: its run id, its task, its log and worktree.
data Child = Child {run :: RunId, task :: TaskId, log :: FilePath, worktree :: FilePath}
    deriving stock (Eq, Show)

-- | A child's hand-back, typed: only 'AsksUp' and 'AwaitsCi' leave it running.
data Said
    = Finished OneLine
    | -- | A question it forwarded up, now pending in this run.
      AsksUp QId
    | -- | CI on its PR, which this run waits on, then resumes the child.
      AwaitsCi OneLine
    | Ended Stop
    deriving stock (Eq, Show)

-- | Where a task's PR stands; the child's own hand-back settles it otherwise.
data TaskState
    = InCi Url
    | InReview Url
    | Merged Url
    | -- | Set aside, and why: a parked task counts as settled.
      Parked Text (Maybe Url)
    deriving stock (Eq, Show)
