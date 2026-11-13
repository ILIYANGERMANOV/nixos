{- | One line of a run's log: what happened, and the envelope that names and
places it. A step's outcome is an 'AnyOutcome' of its layer, named by the
step it ends ("State.Step.Catalog"), so a log is read off the flow's graph. A question is an
'Asking' and the events on its id that close it. The 10x's fan-out logs its
children ('Spawned', 'HandedBack'), the agents it sends ('Spawning',
'Resumed') and its tasks ('TaskMoved', 'Held', 'ActedOn') as stay events.
-}
module State.Run.Event (
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
    AnyOutcome,
    stepTook,
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

import Data.Set (Set)
import Data.Text (Text)
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Category.Flow (FanId (..))
import State.Category.Mode (Quality, Size)
import State.Category.Step (Outcome, StateName (..))
import State.Run.Ask (Above, OneLine, Op (..), Parent (..), Principal (..), Proposal, QId, Question)
import State.Run.Id (Digest (..), EventId (..), RunId, TaskId (..), parseRunId, runIdText)
import State.Step.Artifact (Branch (..), BreakdownError (..), Check (..), Commit (..), DraftPr (..), Judgement (..), Label (..), Picks (..), Requirement (..), Sha (..), Task (..), Tasks, Topic (..), Url (..), breakdown, taskList)
import State.Step.Catalog (AnyOutcome, KnownLayer, outcome)

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
      Took AnyOutcome
    | -- | Terminal: it ends every question still pending too.
      Stopped Stop
    | {- | A question for this run to rule on or forward: its own, or one handed
      up to it, under the id it was first asked by.
      -}
      Asked Asking
    | {- | The question is 'State.Run.Ask.Security' from here on. The event names no
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

-- | The event a step's outcome appends.
stepTook :: (KnownLayer k) => Outcome (s :: k) l -> Event
stepTook = Took . outcome

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
