{- | One line of a run's log: what happened, and the envelope that names and
places it. A step's outcome is an 'AnyOutcome' of its layer, named by the
step it ends ("State.Step.Catalog"), so a log is read off the flow's graph. A question is an
'Asking' and the events on its id that close it. The 10x's fan-out logs its
children ('Spawned', 'HandedBack'), the agents it sends ('Spawning',
'Resumed', 'Restarted') and its tasks ('TaskAdded', 'TaskMoved', 'Held',
'ActedOn') as stay events. A lead logs the workers it has at work
('WorkerSpawned', 'WorkerReturned'), which it hands back after. A line
logged in error is 'Voided', never edited out: replay drops both lines.
-}
module State.Run.Event (
    Envelope (..),
    Source (..),
    EventId (..),
    eventId,
    RunId,
    AgentId (..),
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
    Stop (..),
    StopReason (..),
    Note (..),
    AnyOutcome,
    stepTook,
    tookIn,
    tookEvent,
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
    Shape (..),
    Target (..),
    PlanCall (..),
    Repo (..),
    Topic (..),
    Tasks,
    BreakdownError (..),
    breakdown,
    taskList,
    Child (..),
    Said (..),
    Waiting (..),
    TaskState (..),
) where

import Data.Set (Set)
import Data.Text (Text)
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Category.Flow (ScopePath, qualifyEvent)
import State.Category.Fuel (Fuel)
import State.Category.Step (EventName, Outcome, StateName (..))
import State.Role (AgentRole (..), FlowName (..), roleText)
import State.Run.Ask (Above, OneLine, Op (..), Parent (..), Principal (..), Proposal, QId, Question)
import State.Run.Id (AgentId (..), Digest (..), EventId (..), RunId, TaskId (..), parseRunId, runIdText)
import State.Step.Artifact (Branch (..), BreakdownError (..), Check (..), Commit (..), DraftPr (..), Judgement (..), Label (..), Picks (..), PlanCall (..), Repo (..), Requirement (..), Sha (..), Shape (..), Target (..), Task (..), Tasks, Topic (..), Url (..), breakdown, taskList)
import State.Step.Catalog (AnyOutcome, KnownLayer, outcome, outcomeEvent)

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
      FuelSet Fuel
    | {- | The existing work the request applies feedback to, named at a
      route's hub before its branch: none is new work, so none is logged.
      -}
      Targeted Target
    | {- | The user let the gather loop go on, and why: its researchers and
      questions start afresh.
      -}
      Extended Text
    | {- | A gap the lead saw in the flow or its tools, logged in place of a
      loose notes file: it moves nothing.
      -}
      Gapped Text
    | {- | A step's outcome, or a mode's skip, inside the scopes its step sits
      in: the one event that moves the run. 'tookEvent' is its name on the wire.
      -}
      Took ScopePath AnyOutcome
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
    | -- | A task joins the fan-out after its breakdown: a base fix, an epic's final PR.
      TaskAdded Task
    | {- | The lead's session started afresh, so every agent it had at work
      is gone: no task has one until the 10x sends one again.
      -}
      Restarted
    | {- | A worker's hand-back line 1 the run triages as a question of its own
      (@state ask --from <role>@) before it goes on: a stop, or a question with no kind.
      -}
      WorkerHandedBack AgentRole OneLine
    | {- | The lead spawned a worker of this role, at work until it returns
      (written by the spawn's hook).
      -}
      WorkerSpawned AgentRole AgentId
    | {- | A worker of this role handed back, by its id when the hook knows it:
      it is at work no more.
      -}
      WorkerReturned AgentRole (Maybe AgentId)
    | {- | The line of this seq is void, and why: replay drops it and this
      line, as if neither was logged ("State.Run.Fold").
      -}
      Voided Natural Text
    deriving stock (Eq, Show)

-- | The event a step's outcome appends, at a step in no scope.
stepTook :: (KnownLayer k) => Outcome (s :: k) l -> Event
stepTook = tookIn mempty

-- | The event a step's outcome appends, at a step inside these scopes.
tookIn :: (KnownLayer k) => ScopePath -> Outcome (s :: k) l -> Event
tookIn scope = Took scope . outcome

-- | @security/review.rows@: the graph's edge an outcome takes, and its name in the log.
tookEvent :: ScopePath -> AnyOutcome -> EventName
tookEvent scope = qualifyEvent scope . outcomeEvent

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

-- | A question as it reached this run, and the step the run was at.
data Asking = Asking {question :: Question, step :: StateName, from :: Asker}
    deriving stock (Eq, Show)

-- | Who put the question to this run.
data Asker = Itself | Subagent AgentRole | ChildRun RunId
    deriving stock (Eq, Show)

data Stop = Stop {reason :: StopReason, why :: Text}
    deriving stock (Eq, Show)

-- | @replan@ ends this run; a new run starts at @Ctx@.
data StopReason = Blocked | Failed | Replan | OutOfRounds
    deriving stock (Eq, Show, Enum, Bounded)

-- | A refusal as the reader saw it: what was wrong, and the fix.
data Note = Note {message :: Text, fix :: Text}
    deriving stock (Eq, Show)

-- | A child run of the fan-out: its run id, its task and its worktree.
data Child = Child {run :: RunId, task :: TaskId, worktree :: FilePath}
    deriving stock (Eq, Show)

-- | A child's hand-back, typed: only 'AsksUp' and 'Awaits' leave it running.
data Said
    = Finished OneLine
    | -- | A question it forwarded up, now pending in this run.
      AsksUp QId
    | -- | What it cannot wait on itself, on these refs: this run waits, then resumes the child.
      Awaits Waiting OneLine
    | Ended Stop
    deriving stock (Eq, Show)

-- | What a run with no wakes of its own hands up for a run above to wait on.
data Waiting = Ci | Merge
    deriving stock (Eq, Show, Enum, Bounded)

-- | Where a task's PR stands; the child's own hand-back settles it otherwise.
data TaskState
    = InCi Url
    | InReview Url
    | Merged Url
    | -- | A round's PR, left open on purpose: settled, and no merge awaited.
      Kept Url
    | -- | Another round on this PR, asked of a task in review, kept or merged: open until its child's READY keeps it.
      Round Url
    | -- | Set aside, and why: a parked task counts as settled.
      Parked Text (Maybe Url)
    deriving stock (Eq, Show)
