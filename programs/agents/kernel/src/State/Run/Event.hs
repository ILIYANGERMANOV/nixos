{- | One line of a run's log: what happened, and the envelope that names and
places it. A step's outcome is an 'AnyOutcome' of its layer, named by the
step it ends ("State.Step.Catalog"), so a log is read off the flow's graph. A question is an
'Asking' and the events on its id that close it. The 10x's fan-out logs its
children ('Spawned', 'HandedBack'), the agents it sends ('Spawning',
'Resumed', 'Restarted') and its tasks ('TaskAdded', 'TaskMoved', 'Held',
'ActedOn') as stay events. A lead logs each subagent it spawns as a span
('SpanStarted', 'SpanEnded'), and hands back after those at work; a child
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
    SpanId (..),
    SpanStart (..),
    SpanEnding (..),
    TokenWord (..),
    Usage (..),
    unreported,
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
    RefusalCode (..),
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
    TaskRef (..),
    Task (..),
    Base (..),
    EpicName,
    EpicMove (..),
    NonBlank,
    Shape (..),
    Target (..),
    PlanCall (..),
    Repo (..),
    Topic (..),
    Tasks,
    BreakdownError (..),
    breakdown,
    taskList,
    tasksInOrder,
    builtOn,
    Child (..),
    ChildTask (..),
    Said (..),
    Waiting (..),
    TaskState (..),
    DepsEdit (..),
    Instruction (..),
    InstructionKind (..),
    Verbatim,
    parseVerbatim,
    verbatimText,
    Need (..),
    artifactsOf,
    spansOf,
    placeOf,
) where

import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Artifact (AbsPath, Artifact, Uri)
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
import State.Run.Epic (EpicMove (..))
import State.Run.Gap (Gap, GapMove)
import State.Run.IJson (IJson)
import State.Run.Id (
    AgentId (..),
    Digest (..),
    EventId (..),
    RunId,
    SpanId (..),
    TaskId (..),
    TaskNo (..),
    TaskRef (..),
    parseRunId,
    parseTaskNo,
    runIdText,
    taskNoText,
 )
import State.Run.Stopgap (StopgapAt)
import State.Step.Artifact (
    Base (..),
    Branch (..),
    BreakdownError (..),
    Check (..),
    Commit (..),
    DraftPr (..),
    EpicName,
    Judgement (..),
    Label (..),
    NonBlank,
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
    builtOn,
    taskList,
    tasksInOrder,
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
      Gapped Gap
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
      Spawning TaskRef
    | -- | A child run started for a task, at the fan-out (written by the child's @init@).
      Spawned Child
    | {- | The 10x resumes the child run, which works again until it hands back.
      Its task, if it took one, is copied from the child's 'Spawned'.
      -}
      Resumed RunId (Maybe TaskRef)
    | -- | What a child run's hand-back said, by its run id, and its task as 'Resumed' names it.
      HandedBack RunId (Maybe TaskRef) Said
    | -- | Where a task's PR stands, as the 10x saw it.
      TaskMoved TaskRef TaskState
    | -- | A finding held back from a task's PR, at this url.
      Held TaskRef Url
    | -- | The 10x acted on the task's held wake at this url: it is held no more.
      ActedOn TaskRef Url
    | {- | A task joins the fan-out after its breakdown: a base fix, an epic's
      final PR. It joins the breakdown logged at this seq; with none, it
      starts one, at its own seq.
      -}
      TaskAdded Natural Task
    | {- | The lead's session started afresh, so every agent it had at work
      is gone: no task has one until the 10x sends one again.
      -}
      Restarted
    | {- | A worker's hand-back line 1 the run triages as a question of its own
      (@state ask --from <role>@) before it goes on: a stop, or a question with no kind.
      -}
      WorkerHandedBack AgentRole OneLine
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
      this seq in the same run, if any (@prov:wasDerivedFrom@), and made by
      the agent of this span, if any (@prov:wasGeneratedBy@).
      -}
      ArtifactLogged Artifact (Maybe Natural) (Maybe SpanId)
    | -- | A note under its topic, then its text: context a fresh agent reads.
      Noted Text Text
    | -- | The agent hands the run over to a fresh one, and why.
      HandedOver Handover
    | -- | A harness session started on the run (written by the session-start hook).
      SessionStarted Session
    | {- | The gap logged at this seq of the run moves on: a fix proposed, or
      closed. Taken whatever state the run is in, a finished one too.
      -}
      GapMoved Natural GapMove
    | {- | The run's lead spawned a subagent: a span, named by this line's
      seq, open until a 'SpanEnded' names it (written by the spawn hook).
      -}
      SpanStarted SpanStart
    | -- | The subagent of this span ended, how, and the tokens its own requests used.
      SpanEnded SpanId SpanEnding Usage
    | -- | An epic of the run opened, made ready or merged ("State.Run.Epic").
      EpicMoved EpicName EpicMove
    | -- | The commit a task's branch is at, as the 10x saw it: its status stays.
      TaskHead TaskRef Sha
    | {- | The task builds on another base from here on, and why: its
      dependency merged, or the stack was reordered. Its dependencies change
      too, when the edit names them.
      -}
      TaskBaseChanged TaskRef Base NonBlank DepsEdit
    | {- | The user's instruction, word for word: it retires the active one
      logged at this seq, if one is named (@dcterms:replaces@).
      -}
      Instructed Instruction (Maybe Natural)
    | -- | The user must do something by hand, open until a 'UserNeededDone' names its seq.
      UserNeeded Need
    | -- | The need logged at this seq of the run is done, maybe with a note.
      UserNeededDone Natural (Maybe NonBlank)
    | {- | A stopgap's value from here on, and why: the newest one of its key
      and scope is in force. The kernel never reads it ("State.Run.Stopgap").
      -}
      StopgapSet StopgapAt IJson NonBlank
    | -- | A stopgap is in force no more, and why: unsetting one not set changes nothing.
      StopgapUnset StopgapAt NonBlank
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

{- | A subagent as its spawn saw it: its role, its harness, its brief in
full, the span of the agent that spawned it, and the model the spawn asked for.
-}
data SpanStart = SpanStart
    { role :: AgentRole
    , harness :: Harness
    , brief :: Text
    , parent :: Maybe SpanId
    -- ^ None when the run's lead spawned it, which has no span.
    , model :: Maybe Text
    -- ^ The model the spawn named, when it named one.
    }
    deriving stock (Eq, Show)

{- | How a span ended: its agent handed back, with the token line 1 opened
with and the hand-back in full, or it ended with none. A blocked or failed
hand-back is still one: the token says how it went, not whether it ran.
-}
data SpanEnding = WithHandback TokenWord Text | NoHandback
    deriving stock (Eq, Show)

-- | The word a hand-back's line 1 opens with, one per hand-back token.
data TokenWord = ReadyWord | NeedsDecisionWord | AwaitWord | BlockedWord | FailedWord
    deriving stock (Eq, Show, Bounded, Enum)

{- | The tokens a span's own requests used, its children's aside. A count the
harness did not report is 'Nothing', never 0. @inputTokens@ includes the
two cache counts.
-}
data Usage = Usage
    { inputTokens :: Maybe Natural
    , outputTokens :: Maybe Natural
    , cacheReadTokens :: Maybe Natural
    , cacheWriteTokens :: Maybe Natural
    }
    deriving stock (Eq, Show)

-- | No count reported: what a hand-back piped in by hand knows.
unreported :: Usage
unreported = Usage Nothing Nothing Nothing Nothing

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

-- | A refusal as the reader saw it: its code, what was wrong, and the fix.
data Note = Note {code :: RefusalCode, message :: Text, fix :: Text}
    deriving stock (Eq, Show)

{- | A refusal's stable snake_case name, low-cardinality like OpenTelemetry's
@error.type@: one per refusal constructor, never @other@.
-}
newtype RefusalCode = RefusalCode {codeText :: Text}
    deriving stock (Eq, Ord, Show)

-- | A child run of the fan-out: its run id, what it was spawned for and its worktree.
data Child = Child {run :: RunId, task :: ChildTask TaskRef, worktree :: FilePath}
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
    | {- | Done as the run's rules define it, its PR left open: settled, not
      merged, and no merge awaited.
      -}
      Delivered Url
    deriving stock (Eq, Show)

{- | What a base change does to the task's dependencies: keeps them, or
sets them to these, none to many.
-}
data DepsEdit = DepsKept | DepsSet (Set TaskId)
    deriving stock (Eq, Show)

-- | What the user told the run to keep to, of this kind, in the user's own words.
data Instruction = Instruction {kind :: InstructionKind, text :: Verbatim}
    deriving stock (Eq, Show)

{- | The user's words as given: a character at least that is no space, line
breaks kept. Built by 'parseVerbatim' alone.
-}
newtype Verbatim = Verbatim Text
    deriving stock (Eq, Show)

parseVerbatim :: Text -> Maybe Verbatim
parseVerbatim raw
    | Text.all isSpace raw = Nothing
    | otherwise = Just (Verbatim raw)

verbatimText :: Verbatim -> Text
verbatimText (Verbatim text) = text

-- | What an instruction sets: the run's goal, its scope, a rule to keep, or a permission.
data InstructionKind
    = GoalInstruction
    | ScopeInstruction
    | RuleInstruction
    | PermissionInstruction
    deriving stock (Bounded, Enum, Eq, Show)

{- | What the user must do by hand, the tasks it holds up, by their
breakdowns, and where to do it, if a URL says.
-}
data Need = Need {text :: NonBlank, blocks :: Set TaskRef, url :: Maybe Uri}
    deriving stock (Eq, Show)

-- | The artifacts these lines log, each with its seq.
artifactsOf :: (Foldable t) => t Envelope -> [(Natural, Artifact)]
artifactsOf logged =
    [ (e.seq, artifact) | e <- toList logged, ArtifactLogged artifact _ _ <- [e.event]
    ]

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

-- | The spans these lines start, each with its id.
spansOf :: (Foldable t) => t Envelope -> [(SpanId, SpanStart)]
spansOf logged =
    [(SpanId e.seq, start) | e <- toList logged, SpanStarted start <- [e.event]]
