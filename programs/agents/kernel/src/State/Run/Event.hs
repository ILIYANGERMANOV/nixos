{- | One line of a run's log: what happened, and the envelope that names and
places it. A step's outcome is an 'AnyOutcome' of its layer, named by the
step it ends ("State.Step.Catalog"), so a log is read off the flow's graph. A question is an
'Asking' and the events on its id that close it. The 10x's fan-out logs its
children ('Spawned', 'HandedBack'), the agents it sends ('Spawning',
'Resumed', 'Restarted') and its tasks ('TaskAdded', 'TaskMoved', 'Held',
'ActedOn') as stay events. A lead logs the workers it has at work
('WorkerSpawned', 'WorkerReturned'), which it hands back after; a child
run, the agent leading it that ended with no hand-back ('AgentEnded'). A line
logged in error is 'Voided', never edited out: replay drops both lines.
-}
module State.Run.Event (
    Envelope (..),
    Source (..),
    EventId (..),
    eventId,
    RunId,
    AgentId (..),
    TaskNo (..),
    taskNoText,
    parseTaskNo,
    parseRunId,
    runIdText,
    SessionId (..),
    parseSessionId,
    Digest (..),
    Event (..),
    Start (..),
    Handover (..),
    HandoverReason (..),
    Session (..),
    Harness (..),
    parseHarness,
    FlowName (..),
    Principal (..),
    Parent (..),
    Link (..),
    Op (..),
    Reply (..),
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
    ChildTask (..),
    Said (..),
    Waiting (..),
    TaskState (..),
    artifactsOf,
    placeOf,
) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Artifact (AbsPath, Artifact)
import State.Category.Effect (Waiting (..))
import State.Category.Flow (ScopePath, qualifyEvent)
import State.Category.Step (EventName, Outcome, StateName (..))
import State.Role (AgentRole (..), FlowName (..), roleText)
import State.Run.Ask (
    Above,
    ChildTask (..),
    Link (..),
    OneLine,
    Op (..),
    Parent (..),
    Principal (..),
    Proposal,
    QId,
    Question,
    Reply (..),
 )
import State.Run.Id (
    AgentId (..),
    Digest (..),
    EventId (..),
    RunId,
    TaskId (..),
    TaskNo (..),
    parseRunId,
    parseTaskNo,
    runIdText,
    taskNoText,
 )
import State.Step.Artifact (
    Branch (..),
    BreakdownError (..),
    Check (..),
    Commit (..),
    DraftPr (..),
    Judgement (..),
    Label (..),
    Picks (..),
    PlanCall (..),
    Repo (..),
    Requirement (..),
    Sha (..),
    Shape (..),
    Target (..),
    Task (..),
    Tasks,
    Topic (..),
    Url (..),
    breakdown,
    taskList,
 )
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

-- | A harness session's id; an empty one is no session at all.
parseSessionId :: Text -> Maybe SessionId
parseSessionId raw = if Text.null raw then Nothing else Just (SessionId raw)

data Event
    = Started Start
    | {- | The existing work the request applies feedback to, named at a
      request's Fuel step, before its branch: none is new work, so none is logged.
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
      Answered QId Reply Above
    | {- | The question waits for a later answer, and why: it stays open, and
      only 'Answered' closes it. Not @Parked@: a task's 'TaskState' is.
      -}
      QuestionParked QId OneLine
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
    | {- | The agent leading this child run stopped before it handed back: a
      user's stop, its spawner's, a crash (written by the stop hook).
      -}
      AgentEnded AgentId
    | {- | The chief's request in focus waits, at its node, and where it stands
      in the lead's words: the run opens a new request at its start.
      -}
      Suspended TaskNo OneLine
    | {- | The chief turns to this waiting request, back at its node: the request
      in focus, untouched since it opened, is dropped.
      -}
      Focused TaskNo
    | {- | The line of this seq is void, and why: replay drops it and this
      line, as if neither was logged ("State.Run.Fold").
      -}
      Voided Natural Text
    | {- | The run moved to this worktree, of this GitHub repo when its
      @origin@ names one: the worktree its @init@ logged no longer holds it.
      -}
      WorktreeMoved AbsPath (Maybe Repo)
    | {- | A file or URL the run registered, derived from the artifact of
      this seq in the same run, if any (@prov:wasDerivedFrom@).
      -}
      ArtifactLogged Artifact (Maybe Natural)
    | -- | A note under its topic, then its text: context a fresh agent reads.
      Noted Text Text
    | -- | The agent hands the run over to a fresh one, and why.
      HandedOver Handover
    | -- | A harness session started on the run (written by the session-start hook).
      SessionStarted Session
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
    , goal :: Maybe Text
    {- ^ The run's goal, word for word. Optional, unlike #552's Appendix B:
    its body says every new flag is optional, so a run started with none
    leaves the key out.
    -}
    , worktree :: AbsPath
    -- ^ The git top of the directory @init@ ran in.
    , repo :: Maybe Repo
    -- ^ The worktree's GitHub repo, when its @origin@ names one.
    }
    deriving stock (Eq, Show)

-- | A hand-over to a fresh agent: why, where the work stands, and what to do next.
data Handover = Handover
    { reason :: HandoverReason
    , summary :: Text
    , next :: NonEmpty Text
    }
    deriving stock (Eq, Show)

-- | Why the agent hands over: its context is full, the user asked, or it crashed.
data HandoverReason = Context | User | Crash
    deriving stock (Eq, Show, Enum, Bounded)

-- | A harness session as its session-start hook saw it.
data Session = Session
    { harness :: Harness
    -- ^ The harness's own name for itself, its adapter's constant.
    , transcript :: Maybe AbsPath
    {- ^ The session's transcript file. Optional, unlike #552's Appendix B:
    a harness that writes none (OpenCode) leaves the key out.
    -}
    , trigger :: Text
    {- ^ The hook's own word for why the session started, its @source@:
    @startup@, @resume@, @compact@. Not @source@: an envelope's is who wrote it.
    -}
    , model :: Maybe Text
    -- ^ The model the harness asked for, when the hook names it.
    }
    deriving stock (Eq, Show)

-- | The harness's own name for itself, @claude-code@ or @opencode@: never empty.
newtype Harness = Harness Text
    deriving stock (Eq, Show)

parseHarness :: Text -> Maybe Harness
parseHarness raw = if Text.null raw then Nothing else Just (Harness raw)

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

-- | A child run of the fan-out: its run id, what it was spawned for and its worktree.
data Child = Child {run :: RunId, task :: ChildTask, worktree :: FilePath}
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

-- | The artifacts these lines log, each with its seq.
artifactsOf :: (Foldable t) => t Envelope -> [(Natural, Artifact)]
artifactsOf logged =
    [(e.seq, artifact) | e <- toList logged, ArtifactLogged artifact _ <- [e.event]]

-- | Where these lines leave the run: the worktree and repo it last moved to, else its start's.
placeOf :: (Foldable t) => Start -> t Envelope -> (AbsPath, Maybe Repo)
placeOf start logged =
    fromMaybe
        (start.worktree, start.repo)
        ( listToMaybe
            ( reverse
                [(top, repo) | line <- toList logged, WorktreeMoved top repo <- [line.event]]
            )
        )
