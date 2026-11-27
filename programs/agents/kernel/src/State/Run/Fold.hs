{- | What a run knows is a fold over its log (#351 section 7). A step event
moves the run along one edge of the flow's graph, found by "State.Category.Path", so a
log the fold accepts is a path of @Run(F)@ (law Trace soundness). Every loop
holds a capped step whose meter bounds it, and the stuck rule short-circuits
it (law Bounded).

A question stays pending until this run rules on it, the answer comes down
after a forward, or the run stops. Each is checked against the run's own row
of 'State.Run.Ask.authority', the row of the role its flow runs.
-}
module State.Run.Fold (
    RunState (..),
    Suspension (..),
    Position,
    waitsAt,
    Stage (..),
    stage,
    focusable,
    suspendedAsks,
    trace,
    Worker (..),
    Origin (..),
    ChildId (..),
    Open (..),
    ledger,
    returnOf,
    endSpan,
    agentEndedIn,
    forkingAt,
    childFork,
    untaskedFan,
    Holder (..),
    taskHolder,
    taskRefIn,
    childRefIn,
    addedTo,
    Round (..),
    Problem (..),
    Pending (..),
    Answer (..),
    Waits (..),
    Refusal (..),
    Append (..),
    Answering (..),
    handle,
    replay,
    unvoided,
    runStart,
    fold,
    append,
    appendTo,
    fuelOf,
    targetsAt,
    OnTarget (..),
    shape,
    onRound,
    planSettled,
    settledSkips,
    Stuck (..),
    stuck,
    stuckExits,
    Budget (..),
    budgets,
    extendable,
    usedUp,
    given,
    heldAnswer,
    pendingAt,
    parkedFor,
    askingChildren,
    askedAt,
    nodeName,
    over,
    forks,
    awaitedOpen,
    ScopedFan (..),
    fanAt,
    fanIn,
    currentFan,
    inScope,
) where

import Control.Applicative ((<|>))
import Control.Monad (foldM, void)
import Data.Bifunctor qualified as Bifunctor
import Data.Foldable (for_, toList)
import Data.Functor ((<&>))
import Data.List (find, genericLength, isSuffixOf, partition)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Numeric.Natural (Natural)
import State.Category.Effect (Eff (..), Handler (..))
import State.Category.Flow (
    FanEvent (..),
    Name (..),
    ScopePath,
    fanEvent,
    nameText,
    namedState,
    qualify,
    qualifyText,
    scopeNames,
 )
import State.Category.Fuel (Fuel (..), PerFuel, SkipWhen (..), atFuel)
import State.Category.Graph (
    Arrow (..),
    Cap (..),
    Edge (..),
    GroupAt (..),
    GroupOf (..),
    LoopAt (..),
    Metered (..),
    Node (..),
    OpenGraph (..),
    Place (..),
    innermost,
    outOf,
    placeName,
    places,
 )
import State.Category.Meter (
    AtCap (..),
    Owed (Closes),
    Recorded (..),
    allowed,
    owedBy,
    spentBy,
 )
import State.Category.Path (awaitDone, forkPasses, step)
import State.Category.Step (
    EventName,
    Outcome,
    SomeOutcome (..),
    SomeStep (..),
    StepSet (stepName),
    stateNameText,
    stepAwaits,
 )
import State.FlowName (FlowName (..))
import State.Role qualified as Role
import State.Run.Ask (
    Above,
    Kind (Security),
    OneLine,
    Principal (..),
    Proposal (..),
    QId (..),
    Question (..),
    Reply (..),
    Ruling,
    deliver,
    flattened,
    oneLineText,
    principalPlan,
    principalShape,
 )
import State.Run.Ask qualified as Ask
import State.Run.Event (
    AgentId (..),
    AgentRole,
    Asker (..),
    Asking (..),
    Check,
    Child (..),
    ChildTask (..),
    DraftPr,
    Envelope (..),
    Event (..),
    EventId,
    Judgement (..),
    Label,
    Note,
    Picks (..),
    PlanCall (ParentDecided),
    Requirement,
    RunId,
    Said (Ended),
    Shape (..),
    SpanEnding,
    SpanId (..),
    Start (..),
    StateName (..),
    Stop,
    StopReason (Failed),
    Target (..),
    Task,
    TaskId,
    TaskRef (..),
    TaskNo (..),
    TaskState (InCi, InReview, Kept, Merged, Parked),
    Url,
    Usage,
    eventId,
    taskNoText,
    tookEvent,
    unreported,
 )
import State.Run.Event qualified as Event
import State.Run.Fan (Breakdown (..), Fan (..), emptyFan)
import State.Run.Fan qualified as Fan
import State.Run.Gap (Closure, GapMove, Tracked (..))
import State.Run.Gap qualified as Gap
import State.Step.Build (BuildStep, Outcome (..))
import State.Step.Catalog (AnyOutcome (..), AnyStep (..), Layer (..), stepNamed)
import State.Step.Fan (FanStep, Outcome (..), fanNamed, fanOf, mergeName)
import State.Step.Fuel (FuelStep, Outcome (..), Sing (Fuel, Skip))
import State.Step.Pick (PickStep)
import State.Step.Plan (refineName)
import State.Step.Request (Outcome (..), RequestStep)
import State.Step.Request qualified as Request
import State.Step.Review (Outcome (..), ReviewStep)
import State.Step.Ship (Outcome (..), ShipStep, Sing (Ready))
import State.Step.Ticket (Outcome (..), TicketStep)

data RunState = RunState
    { run :: RunId
    , start :: Start
    , at :: Node
    , fuel :: Maybe Fuel
    -- ^ 'Nothing' until recorded: 'fuelOf' reads the default meanwhile.
    , rounds :: Map Name (NonEmpty Round)
    -- ^ The rounds so far of each loop the run is inside, oldest first.
    , seen :: Set EventId
    , stopped :: Maybe Stop
    , refused :: Maybe Note
    -- ^ The refusal logged last, until the next event.
    , pending :: [Pending]
    -- ^ Oldest first.
    , everAsked :: Set QId
    -- ^ Every question asked, open or closed: a retried ask is refused, so it is never ruled twice.
    , meters :: Map Metered Natural
    {- ^ What the run spent of each capped step's budget since it entered the
    innermost loop around the step's state, or extended it: none spent is absent.
    -}
    , askedHere :: [Question]
    {- ^ The questions asked since the run last moved, oldest first: advice asks a step's
    question once. Also emptied when a question uses up its step's budget, so the
    question whether to go on is asked after that, whatever was asked before.
    -}
    , rulings :: [Ruling]
    -- ^ Every ruling the run made, oldest first: @show@ and the hand-back list them (law Audit).
    , answers :: [Answer]
    -- ^ Every forwarded question answered from above, oldest first: @show@ lists them.
    , gaps :: [(Natural, Tracked)]
    {- ^ Every gap the run logged with its line's seq, and where its fix
    stands, oldest first: @show@ lists them, @state void@ and @state gap@ take the seq.
    -}
    , drafted :: Maybe DraftPr
    -- ^ The draft PR the run recorded last: its url when GitHub is not read.
    , untriaged :: [(AgentRole, OneLine)]
    -- ^ The workers' hand-backs the run has yet to ask as its own question, oldest first.
    , workers :: [Worker]
    {- ^ The agents spawned that have yet to return, oldest first: the run
    hands back after them. The agent children of the run's 'ledger'. Each
    open span is one, whatever its role: a reader that waits counts those
    of the roles it waits on.
    -}
    , agentEnded :: Maybe AgentId
    {- ^ The agent leading this child run that stopped with no hand-back: a
    fresh one resumes the run from its notes. None once a step moves it again.
    -}
    , published :: Maybe Url
    {- ^ The PR @ready@ recorded last: the url of a run that skipped its draft
    by override, as a retry does, when GitHub is not read.
    -}
    , fans :: Map ScopedFan Fan
    -- ^ Each fan-out's tasks and child runs, by its name in its scopes: none before its breakdown.
    , ticket :: Maybe Url
    -- ^ The ticket @ticket@ recorded last: the url an architect run names at its end.
    , latest :: Maybe Url
    {- ^ The PR or ticket url any step recorded last: what a chief's request
    ended in, as an earlier request's PR must not stand for a later ticket.
    -}
    , onTarget :: Maybe OnTarget
    -- ^ The existing work the request applies feedback to: none for new work, and on each new request.
    , focus :: TaskNo
    -- ^ The chief's request in focus, the one the fields above place: a run of another flow has one.
    , suspended :: Map TaskNo Suspension
    -- ^ The chief's requests waiting, each where it stood.
    }
    deriving stock (Eq, Show)

{- | A waiting request: where it stood, where it stands in the lead's words,
and its own questions then open, with how each waited. Those wait apart,
not on the request in focus.
-}
data Suspension = Suspension {position :: Position, summary :: OneLine, asks :: [(QId, Waits)]}
    deriving stock (Eq, Show)

{- | Where a request stands: what turning back to it restores, a
defunctionalised continuation's label and live locals. The run's fields of
these names, in their order; positional, as a record's update of a field
two records name is ambiguous.
-}
data Position
    = Position
        Node
        (Maybe Fuel)
        (Map Name (NonEmpty Round))
        (Map Metered Natural)
        [Question]
        (Maybe OnTarget)
        (Maybe Url)
    deriving stock (Eq, Show)

-- | The node a waiting request stands at.
waitsAt :: Suspension -> Node
waitsAt (Suspension (Position at _ _ _ _ _ _) _ _) = at

{- | A request's target, and whether a Design or Scope question was asked
since it was named: then the user confirms its plan after all.
-}
data OnTarget = OnTarget {target :: Target, designAsked :: Bool}
    deriving stock (Eq, Show)

{- | A worker at work: its role, the line that opened it, and that line's
seq, a span's id ('SpanId').
-}
data Worker = Worker {role :: AgentRole, origin :: Origin, spawnedAt :: Natural}
    deriving stock (Eq, Show)

{- | The line that opened a worker: a @span_started@, or a @worker_spawned@
from before spans (logged at the bind, it names the agent's id).
-}
data Origin = SpanLine | WorkerLine AgentId
    deriving stock (Eq, Show)

-- | A child of the run: an agent it spawned, a child run of its fan-out, or a span.
data ChildId = AgentChild AgentId | RunChild RunId | SpanChild SpanId
    deriving stock (Eq, Show)

-- | A child of the run spawned and yet to return or hand back its end, and the role that runs it.
data Open = Open {child :: ChildId, role :: AgentRole}
    deriving stock (Eq, Show)

{- | The run's open children, agents first, each oldest first: what a group's
'State.Category.Flow.Await' waits on, those of its role. An agent's entry
opens at its spawn and closes when it ends ('SpanEnded'). A child
run's is its task book's: running ('Fan.running'), on a task not settled,
as parking a task settles even a lost child. Derived, not stored: the task
book holds each child's hand-backs, its last one says whether it runs on.
-}
ledger :: OpenGraph -> RunState -> [Open]
ledger g state =
    [Open (childOf worker) worker.role | worker <- state.workers]
        <> [ Open (RunChild childRun.child.run) group.runner
           | (scoped, fan) <- Map.toList state.fans
           , (place, Awaiting group) <- Map.toList g.groupStates
           , place.scope == scoped.scope
           , place.name == namedState scoped.fan
           , childRun <- Fan.running fan
           , unsettled fan childRun.child.task
           ]
  where
    childOf worker = case worker.origin of
        SpanLine -> SpanChild (SpanId worker.spawnedAt)
        WorkerLine agent -> AgentChild agent
    -- An untasked child is open while it runs.
    unsettled fan = \case
        Tasked ref -> not (Fan.settled fan ref.task)
        Untasked -> True

-- | A forwarded question, the answer that came down for it, and the state the question was asked at.
data Answer = Answer {about :: Question, given :: Reply, step :: StateName}
    deriving stock (Eq, Show)

-- | A question asked and not yet ruled on, answered or ended by a stop.
data Pending = Pending {asking :: Asking, waits :: Waits}
    deriving stock (Eq, Show)

data Waits
    = -- | For this run to rule on it or forward it.
      ForTriage
    | -- | Forwarded, for the answer to come down.
      ForAnswer
    | -- | Parked, and why: for an answer later, which alone closes it.
      ForLater OneLine
    deriving stock (Eq, Show)

-- | What went wrong in one round of a loop, which the stuck rule compares two of.
newtype Round = Round {found :: Set Problem}
    deriving stock (Eq, Show)

data Problem = Row Label | Unmet Requirement | Failing Check
    deriving stock (Eq, Ord, Show)

data Refusal
    = -- | The log's first line is not @started@.
      NotStarted
    | StartedTwice
    | OtherRun RunId
    | -- | Nothing happens after a @stop@ but a logged refusal.
      AfterStop Stop
    | -- | The flow has no edge on this event where the run is.
      NoEdge Node EventName
    | -- | The run's Fuel never skips this step.
      NotSkippable Name
    | -- | The event would spend past its step's cap, which allows this many at the run's Fuel.
      OutOfBudget Cap Natural
    | -- | A move off a group's 'State.Category.Flow.Await' while this many of its children have yet to hand back.
      StillOpen Natural
    | -- | An @extend@ where no budget the user may extend holds the run.
      NothingToExtend
    | -- | A target named off a Fuel step: only a request's Fuel, before its branch, names one.
      TargetOffFuel
    | -- | An override names a state the flow does not have, or more than one.
      NoSingleState StateName
    | -- | The question was asked already, whether pending or closed.
      AskedTwice QId
    | NotPending QId
    | -- | Forwarded already: only its answer is left.
      AlreadyForwarded QId
    | -- | An answer to a question the run never forwarded.
      NotForwarded QId
    | -- | Parked: only its answer is left.
      IsParked QId
    | -- | Another answer to a question answered already with this one.
      AnsweredOtherwise QId Reply
    | -- | The run's row of 'State.Run.Ask.authority' does not allow it.
      NotAllowed Ask.Refusal
    | -- | A forward or answer naming another than whoever started the run.
      NotAbove Above
    | FanRefused Fan.Refusal
    | -- | A child's or a task's event where the run is at no fan-out's breakdown, own state or merge.
      NotAtFan
    | -- | A task's event no request's fan-out holds, or more than one: the requests that hold it.
      NotOneHolder TaskId [TaskNo]
    | -- | A void naming no line the run replays: no such seq, a line voided already, or a void.
      NotVoidable Natural
    | -- | A void of this seq leaves a log that does not replay, for this refusal.
      VoidBreaks Natural Refusal
    | -- | A request switch in a run that switches none: not a chief's, or one over.
      NoFocus
    | -- | A suspension naming another request than the one in focus.
      NotInFocus TaskNo
    | -- | A turn to a request that is not waiting: unknown, done, or in focus.
      NotSuspended TaskNo
    | -- | A turn away from the request in focus, which recorded work: it is suspended first.
      FocusRecorded TaskNo
    | -- | A gap's status event naming a seq whose line is no gap of the run.
      UnknownGap Natural
    | -- | A status event for the gap of this seq, which closed already so.
      GapClosed Natural Closure
    | -- | The end of a span that is not open: never started, ended already, or lost to a restart.
      SpanNotOpen SpanId
    deriving stock (Eq, Show)

{- | An id already in the log, or an answer the run holds already, is not
appended twice: the append is a no-op.
-}
data Append = Appended RunState | AlreadyLogged
    deriving stock (Eq, Show)

{- | A whole log, from its @started@ line, less each void and the line it
names. Their ids stay seen, so a hook fired again does not log its voided
line anew.
-}
replay :: OpenGraph -> NonEmpty Envelope -> Either Refusal RunState
replay g logged = do
    lines' <- trace g logged
    let after = snd (NonEmpty.last lines')
    Right
        after
            { seen =
                after.seen
                    <> Set.fromList (map eventId (snd (unvoided (NonEmpty.toList logged))))
            }

{- | Each line a replay keeps, with the run just after it: what reading the
log line by line, as the requests' cards do, sees.
-}
trace ::
    OpenGraph -> NonEmpty Envelope -> Either Refusal (NonEmpty (Envelope, RunState))
trace g logged = case fst (unvoided (NonEmpty.toList logged)) of
    [] -> Left NotStarted
    first : rest -> do
        state <- begin g first
        NonEmpty.reverse <$> foldM next ((first, state) :| []) rest
  where
    next done@((_, state) :| _) envelope =
        append g state envelope <&> \case
            Appended after -> NonEmpty.cons (envelope, after) done
            AlreadyLogged -> done

-- | The lines a replay keeps, and those it drops: each void and the line it names.
unvoided :: [Envelope] -> ([Envelope], [Envelope])
unvoided logged = partition (\envelope -> Set.notMember envelope.seq voided) logged
  where
    voided =
        Set.fromList
            (concat [[envelope.seq, n] | envelope <- logged, Voided n _ <- [envelope.event]])

{- | One more line to the log the state replays. A void is no step of the
fold, so the log is replayed with it: it must name a line the replay keeps,
and the log without that line must still replay.
-}
appendTo ::
    OpenGraph -> RunState -> NonEmpty Envelope -> Envelope -> Either Refusal Append
appendTo g state logged envelope
    | Voided n _ <- envelope.event = voiding n
    | otherwise = append g state envelope
  where
    voiding n
        | n `notElem` map (.seq) (fst (unvoided (NonEmpty.toList logged))) =
            Left (NotVoidable n)
        | otherwise =
            Appended <$> Bifunctor.first (VoidBreaks n) (replay g (logged <> pure envelope))

-- | The log's events after a state: @fold (a <> b) = fold a >=> fold b@.
fold :: OpenGraph -> RunState -> [Envelope] -> Either Refusal RunState
fold g = foldM $ \state envelope ->
    append g state envelope >>= \case
        Appended next -> Right next
        AlreadyLogged -> Right state

-- | One more line, as the log's one writer appends it.
append :: OpenGraph -> RunState -> Envelope -> Either Refusal Append
append g state envelope
    | Set.member (eventId envelope) state.seen = Right AlreadyLogged
    | envelope.run /= state.run = Left (OtherRun envelope.run)
    -- Written down from above, then given again by the run's own agent, or retried: still from above.
    | Answered qid answer by <- envelope.event
    , Just answer == heldAnswer state qid =
        AlreadyLogged <$ fromAbove state.start.principal by
    -- The PR proposed already, proposed again: a retry, logged once.
    | GapMoved n move <- envelope.event
    , Just Gap.Again <- (`Gap.transition` move) . (.status) <$> lookup n state.gaps =
        Right AlreadyLogged
    | otherwise = do
        next <- applyEvent g state envelope.seq envelope.event
        Right (Appended next {seen = Set.insert (eventId envelope) state.seen})

begin :: OpenGraph -> Envelope -> Either Refusal RunState
begin g envelope = case runStart envelope.event of
    Nothing -> Left NotStarted
    Just start ->
        Right
            RunState
                { run = envelope.run
                , start
                , at = At g.inPort
                , fuel = Nothing
                , rounds =
                    Map.mapMaybe
                        (\loop -> if Set.member g.inPort loop.body then Just firstRound else Nothing)
                        g.loops
                , seen = Set.singleton (eventId envelope)
                , stopped = Nothing
                , refused = Nothing
                , pending = []
                , everAsked = Set.empty
                , meters = Map.empty
                , askedHere = []
                , rulings = []
                , answers = []
                , gaps = []
                , drafted = Nothing
                , published = Nothing
                , untriaged = []
                , workers = []
                , agentEnded = Nothing
                , fans = Map.empty
                , ticket = Nothing
                , latest = Nothing
                , onTarget = Nothing
                , focus = TaskNo 1
                , suspended = Map.empty
                }

-- | The run an event starts: a log's first line must start one.
runStart :: Event -> Maybe Start
runStart = \case
    Started start -> Just start
    Targeted _ -> Nothing
    Extended _ -> Nothing
    Gapped _ -> Nothing
    Took _ _ -> Nothing
    Stopped _ -> Nothing
    Overridden _ _ -> Nothing
    Refused _ -> Nothing
    Asked _ -> Nothing
    RetaggedSecurity _ -> Nothing
    RuledOn _ _ -> Nothing
    Forwarded _ _ -> Nothing
    Answered {} -> Nothing
    QuestionParked _ _ -> Nothing
    Spawning _ -> Nothing
    Spawned _ -> Nothing
    Resumed _ _ -> Nothing
    HandedBack {} -> Nothing
    TaskMoved _ _ -> Nothing
    Held _ _ -> Nothing
    ActedOn _ _ -> Nothing
    TaskAdded _ _ -> Nothing
    Restarted -> Nothing
    WorkerHandedBack _ _ -> Nothing
    WorkerSpawned _ _ -> Nothing
    WorkerReturned _ _ -> Nothing
    AgentEnded _ -> Nothing
    Suspended _ _ -> Nothing
    Focused _ -> Nothing
    Voided _ _ -> Nothing
    WorktreeMoved _ _ -> Nothing
    ArtifactLogged {} -> Nothing
    Noted _ _ -> Nothing
    HandedOver _ -> Nothing
    SessionStarted _ -> Nothing
    GapMoved _ _ -> Nothing
    SpanStarted _ -> Nothing
    SpanEnded {} -> Nothing

{- | The logged event that answers an effect ('Eff'), its handler's input. A
run's live command and its replay append the same event, so one handler
serves both: live makes the event, then appends it ('appendTo').
-}
data Answering (eff :: Eff) where
    -- | The branch the agent picked: the pick step's outcome, in its scopes, logged at this seq.
    Picked :: Natural -> ScopePath -> SomeOutcome PickStep -> Answering PickE
    -- | A question put to this run, one of its own or one handed up.
    Asks :: Asking -> Answering AskE
    Retags :: QId -> Answering AskE
    RulesOn :: QId -> Proposal -> Answering AskE
    Forwards :: QId -> Above -> Answering AskE
    -- | The answer that came down, and who gave it.
    Answers :: QId -> Reply -> Above -> Answering AskE
    -- | The question waits for a later answer, and why.
    Parks :: QId -> OneLine -> Answering AskE
    -- | The chief's request in focus waits, and where it stands: a new request opens.
    Suspends :: TaskNo -> OneLine -> Answering FocusE
    -- | The chief turns back to this waiting request.
    Focuses :: TaskNo -> Answering FocusE
    -- | The outcome of the step that waits, in its scopes, logged at this seq: what it waited on settled.
    Settles :: Natural -> ScopePath -> AnyOutcome -> Answering AwaitE

{- | The handler's run once the event answers its effect, or why the event
does not: pure, so a replay of the log gives the run its live commands gave.
-}
handle ::
    Handler eff -> OpenGraph -> RunState -> Answering eff -> Either Refusal RunState
handle handler g state = case handler of
    PickHandler -> \(Picked n scope some) -> pick g state n scope some
    AskHandler -> \case
        Asks asking -> fromChild asking.from <$> asked g state asking
        Retags qid -> retagged state qid
        RulesOn qid proposal -> ruledOn state qid proposal
        Forwards qid to -> forwarded state qid to
        Answers qid reply by -> answered state qid reply by
        Parks qid why -> parked state qid why
    FocusHandler -> \answering ->
        focusable state >> case answering of
            Suspends task summary -> suspends g state task summary
            Focuses task -> focuses g state task
    AwaitHandler -> \(Settles n scope outcome) -> took g state n scope outcome

{- | A pick moves along its label's edge, unless the budget of the step it
enters is used up: the advice offers only the actions a budget leaves, so
a pick never strands the run at a step it may not spend.
-}
pick ::
    OpenGraph ->
    RunState ->
    Natural ->
    ScopePath ->
    SomeOutcome PickStep ->
    Either Refusal RunState
pick g state n scope some = do
    let outcome = AnyOutcome PickLayer some
    for_ (edgeHere g state (tookEvent scope outcome)) $ \(_, edge) -> maybe (Right ()) Left (usedUpAt g state edge)
    walked g state n scope outcome

-- | A question asked from a stopped child is its stop, triaged; from a worker, its oldest hand-back.
fromChild :: Asker -> RunState -> RunState
fromChild from after = case from of
    -- A run id is its child's alone: whichever request's fan-out holds it, only it is marked.
    ChildRun child -> after {fans = Map.map (Fan.triaged child) after.fans}
    Itself -> after
    Subagent role -> after {untriaged = triagedBy role after.untriaged}

-- | A refusal is logged whatever the run's state; anything else needs a run going. @n@ is the event's seq.
applyEvent ::
    OpenGraph -> RunState -> Natural -> Event -> Either Refusal RunState
applyEvent g state n = \case
    Refused note -> Right state {refused = Just note}
    Started _ -> going (Left StartedTwice)
    Targeted target -> going (targeted state target)
    Extended _ -> going (extended g state)
    Gapped gap -> going (Right state {gaps = state.gaps <> [(n, Tracked gap Gap.Open)]})
    -- A step moved: an agent works the run again.
    Took scope (AnyOutcome PickLayer some) -> going (working <$> handle PickHandler g state (Picked n scope some))
    Took scope outcome@(AnyOutcome _ (SomeOutcome s _ _))
        | stepAwaits s ->
            going (working <$> handle AwaitHandler g state (Settles n scope outcome))
        | otherwise -> going (working <$> took g state n scope outcome)
    Stopped stop -> going (Right state {stopped = Just stop, pending = []})
    Overridden name _ -> going (overridden g state name)
    Asked asking -> going (handle AskHandler g state (Asks asking))
    RetaggedSecurity qid -> going (handle AskHandler g state (Retags qid))
    RuledOn qid proposal -> going (handle AskHandler g state (RulesOn qid proposal))
    Forwarded qid to -> going (handle AskHandler g state (Forwards qid to))
    Answered qid reply by -> going (handle AskHandler g state (Answers qid reply by))
    QuestionParked qid why -> going (handle AskHandler g state (Parks qid why))
    Spawning ref -> going (inTaskFan ref.task (Fan.spawning (askingChildren state) ref.task))
    Spawned child -> going $ case child.task of
        Tasked ref ->
            heldTask ref.task >>= \holder ->
                atAwait g holder.at
                    >> inFanAt holder.fan (Fan.spawned (askingChildren state) child) state
        Untasked -> forked g state child
    Resumed child _ -> going (inFanOf (snd (childAt child)) (Fan.resumed child))
    -- An untasked child hands back wherever the run is, as an agent child does.
    HandedBack child _ said -> going $ case untaskedFan state child of
        Just fan -> inFanAt fan (Fan.handedBack child said) state
        Nothing ->
            let (at, fan) = childAt child
             in atFan g at HandsBack >> inFanOf fan (Fan.handedBack child said)
    -- 'Fan.moved' ignores a merged task's later move, so the run skips its effects too.
    TaskMoved TaskRef {task} moved ->
        going $
            heldTask task >>= \holder -> do
                let before = fanIn state.fans holder.fan
                after <- inFanAt holder.fan (Fan.moved task moved) state
                if Fan.merged before task
                    then Right after
                    else afterMove holder.requests before task moved after
    Held ref url -> going (inTaskFan ref.task (Fan.held ref.task url))
    ActedOn ref url -> going (inTaskFan ref.task (Fan.actedOn ref.task url))
    -- A new task joins the fan-out the run is at: no request holds it yet.
    TaskAdded _ task -> going (inFanOf (fanAt state.at) (Fan.added n task) >>= reopened g)
    -- The lead's session started afresh: every agent it had at work is gone.
    Restarted -> going (Right state {fans = Map.map Fan.restarted state.fans, workers = []})
    WorkerHandedBack role line -> going (Right state {untriaged = state.untriaged <> [(role, line)]})
    WorkerSpawned role agent ->
        going
            (Right state {workers = state.workers <> [Worker role (WorkerLine agent) n]})
    WorkerReturned role agent -> going (Right state {workers = returned role agent state.workers})
    AgentEnded agent -> going (Right state {agentEnded = Just agent})
    Suspended task summary -> going (handle FocusHandler g state (Suspends task summary))
    Focused task -> going (handle FocusHandler g state (Focuses task))
    -- Context facts for a fresh agent: they move nothing.
    WorktreeMoved _ _ -> going (Right state)
    ArtifactLogged {} -> going (Right state)
    Noted _ _ -> going (Right state)
    HandedOver _ -> going (Right state)
    SessionStarted _ -> going (Right state)
    -- A gap's fix may land after its run stopped or finished: taken in any state.
    GapMoved target move -> (\after -> after {refused = Nothing}) <$> gapMoved state target move
    SpanStarted start ->
        going (Right state {workers = state.workers <> [Worker start.role SpanLine n]})
    SpanEnded ended _ _ -> going $ case break (isSpan ended) state.workers of
        (before, _ : after) -> Right state {workers = before <> after}
        (_, []) -> Left (SpanNotOpen ended)
    -- A replay drops every void, so only an 'append' that is no 'appendTo' meets one.
    Voided target _ -> Left (NotVoidable target)
  where
    working after = after {agentEnded = Nothing}
    {- A round reopens the fan-out of the request in focus only: a waiting
    request's cursor stays where it stood, so its merge, on the turn back,
    is refused until the round's task settles (a rare case, left as is). -}
    afterMove requests fan task = \case
        Event.Round _
            | state.focus `elem` requests -> reopened g
            | otherwise -> Right
        InCi _ -> Right
        InReview _ -> Right
        Merged _ -> Right
        Kept _ -> Right
        Parked _ _ -> Right . unaskedBy fan task
    -- A task's event goes to the one request's fan-out that holds the task, whichever has focus.
    heldTask task = Bifunctor.first (NotOneHolder task) (taskHolder state task)
    inTaskFan task change = heldTask task >>= \holder -> inFanAt holder.fan change state
    {- A tasked child's event goes to the request's fan-out that holds it; any
    other, to the fan-out the run is at, which refuses a child it lacks. -}
    childAt child =
        maybe
            (state.at, fanAt state.at)
            (\holder -> (holder.at, Just holder.fan))
            (childHolder state child)
    inFanOf scoped change = case scoped of
        Just fan -> inFanAt fan change state
        Nothing -> Left NotAtFan
    -- After any event, a state that goes on by itself does ('joined').
    going next = case state.stopped of
        Just stop -> Left (AfterStop stop)
        Nothing -> (\moved -> joined g moved {refused = Nothing}) <$> next

{- | The gap of this seq moved on, as 'Gap.transition' allows. A repeat
is no line at all ('append'), so it never reaches here; met, it changes nothing.
-}
gapMoved :: RunState -> Natural -> GapMove -> Either Refusal RunState
gapMoved state target move = case lookup target state.gaps of
    Nothing -> Left (UnknownGap target)
    Just tracked -> case Gap.transition tracked.status move of
        Gap.To status ->
            Right
                state
                    { gaps =
                        [ (n, if n == target then Tracked tracked.gap status else other)
                        | (n, other) <- state.gaps
                        ]
                    }
        Gap.Again -> Right state
        Gap.Shut closure -> Left (GapClosed target closure)

{- | A target is named at a request's Fuel step, before its level: its
request's work is on it, so a PR, draft or ticket an earlier request
recorded is not its own.
-}
targeted :: RunState -> Target -> Either Refusal RunState
targeted state target = case state.at of
    At place
        | targetsAt state.start.flow place ->
            Right
                state
                    { onTarget = Just (OnTarget target False)
                    , drafted = Nothing
                    , published = Nothing
                    , ticket = Nothing
                    }
    _ -> Left TargetOffFuel

{- | Whether a target may be named here: only at a chief request's Fuel
steps, its own or its routed flow's. A flow run on its own takes its PR
from its init, never a target.
-}
targetsAt :: FlowName -> Place -> Bool
targetsAt flow place = case flow of
    ChiefFlow -> place.name == stepName Fuel
    EngineerFlow -> False
    TenXFlow -> False
    ArchitectFlow -> False

{- | The worker gone from those at work: the one of that id, else the oldest
of that role, as a hand-back piped in by hand names no id.
-}
returned :: AgentRole -> Maybe AgentId -> [Worker] -> [Worker]
returned role agent workers = case break (returning role agent) workers of
    (before, _ : after) -> before <> after
    (before, []) -> before

{- | What the parent records when the agent leading its child run ended with
no hand-back: an untasked child's stop, which closes it in the 'ledger',
else the agent's return when it was at work ('returnOf').
-}
agentEndedIn :: RunState -> RunId -> AgentRole -> AgentId -> Maybe Event
agentEndedIn state child role agent = case untaskedFan state child of
    Just _ ->
        Just
            ( HandedBack
                child
                Nothing
                ( Ended
                    (Event.Stop Failed ("agent " <> agent.agentIdText <> " ended with no hand-back"))
                )
            )
    Nothing -> returnOf state role (Just agent) Event.NoHandback

{- | The event saying a worker of this role returned, ended so, when it is
one at work: none for another. With no id, the oldest of the role returns,
so a span lost to a restart is never the one.
-}
returnOf :: RunState -> AgentRole -> Maybe AgentId -> SpanEnding -> Maybe Event
returnOf state role agent ending = returnedAs <$> find (returning role agent) state.workers
  where
    returnedAs worker = case worker.origin of
        SpanLine -> SpanEnded (SpanId worker.spawnedAt) ending unreported
        WorkerLine _ -> WorkerReturned role agent

returning :: AgentRole -> Maybe AgentId -> Worker -> Bool
returning role agent worker = maybe (worker.role == role) ((== worker.origin) . WorkerLine) agent

{- | The event ending this span so, when it is open: none for one that
ended already, never started or was lost to a restart. Every writer of a
span's end asks here, the rule the fold refuses by ('SpanNotOpen').
-}
endSpan :: RunState -> SpanId -> SpanEnding -> Usage -> Maybe Event
endSpan state ended ending usage = SpanEnded ended ending usage <$ find (isSpan ended) state.workers

isSpan :: SpanId -> Worker -> Bool
isSpan ended worker = worker.origin == SpanLine && SpanId worker.spawnedAt == ended

-- | The worker's oldest hand-back gone, once the run asked it as a question.
triagedBy :: AgentRole -> [(AgentRole, OneLine)] -> [(AgentRole, OneLine)]
triagedBy role untriaged = case break ((== role) . fst) untriaged of
    (before, _ : after) -> before <> after
    (before, []) -> before

{- | Moves along the outcome's edge, after the outcome spends its step's
meter and its problems join the rounds it ends. A forked child's hand-back
(@research.handed_back@) is taken anywhere, before its bind too, and
changes nothing: its agent's return closes its entry in the 'ledger'.
-}
took ::
    OpenGraph -> RunState -> Natural -> ScopePath -> AnyOutcome -> Either Refusal RunState
took g state n scope outcome@(AnyOutcome _ some)
    | any (\cap -> owedBy cap.meter (RecordedOutcome some) == Just Closes) g.caps =
        Right state
    | otherwise = walked g state n scope outcome

{- | A group's 'State.Category.Flow.Await' goes on by itself once every
child handed back (an AND-join): no one records its @done@, as the
run's ledger already holds the fact. A parallel's fork state goes on at once
('forkPasses'). At any other state, the run stays.
-}
joined :: OpenGraph -> RunState -> RunState
joined g state = case state.at of
    At place
        | Just edge <- awaitDone g place
        , awaitedOpen g state place == 0 ->
            joined g (movedOn g edge state)
        | Just edge <- forkPasses g place -> joined g (movedOn g edge state)
    At _ -> state
    Out -> state
    Exit -> state

-- | The run along an edge no outcome names: an await's done, a fork's spawn.
movedOn :: OpenGraph -> Edge Node -> RunState -> RunState
movedOn g edge state =
    state
        { at = edge.to
        , rounds = enter g edge.back state.at edge.to state.rounds
        , meters = kept g edge.to state.meters
        , askedHere = []
        }

{- | An untasked child's @init@: the run is at the 'State.Category.Flow.Fork'
of a group of child runs ('forkingAt'), and goes on by its @spawned@. The
child is kept in the fan-out of the group's 'State.Category.Flow.Await',
where the 'ledger' counts it open until it finishes or stops.
-}
forked :: OpenGraph -> RunState -> Child -> Either Refusal RunState
forked g state child = case forkingAt g state of
    Just (edge, fan) ->
        movedOn g edge <$> inFanAt fan (Fan.spawned (askingChildren state) child) state
    Nothing -> Left (NoEdge state.at (fanEvent Spawns (askedAt state)))

-- | The run with this fan-out changed, or the fan-out's refusal.
inFanAt ::
    ScopedFan ->
    (Fan -> Either Fan.Refusal Fan) ->
    RunState ->
    Either Refusal RunState
inFanAt fan change state =
    (\changed -> state {fans = Map.insert fan changed state.fans})
        <$> Bifunctor.first FanRefused (change (fanIn state.fans fan))

-- | The run is at a fork of child runs ('childFork'): its edge on, and the fan-out its child joins.
forkingAt :: OpenGraph -> RunState -> Maybe (Edge Node, ScopedFan)
forkingAt g state = case state.at of
    At place -> childFork g place
    Out -> Nothing
    Exit -> Nothing

{- | A 'State.Category.Flow.Fork' of child runs, its group's runner leading
a flow: the @spawned@ edge on, which the child's init takes, and the fan-out
of the group's 'State.Category.Flow.Await' the child joins. A fork of
agents, the researchers, is none.
-}
childFork :: OpenGraph -> Place -> Maybe (Edge Node, ScopedFan)
childFork g place = case Map.lookup place g.groupStates of
    Just (Forking group) -> do
        _ <- Role.leads group.runner
        edge <- step g place (fanEvent Spawns place.name)
        (edge,)
            <$> listToMaybe
                [ ScopedFan awaited.scope (Name name)
                | (awaited, Awaiting other) <- Map.toList g.groupStates
                , other == group
                , StateName name <- [awaited.name]
                ]
    Just (Awaiting _) -> Nothing
    Nothing -> Nothing

{- | A fan-out of the run's requests, the one in focus or a waiting one, with
what it holds of an event: two requests at one fan-out share it. The node
is where its first request stands, the one in focus when it is one of them.
-}
data Holder a = Holder {requests :: NonEmpty TaskNo, at :: Node, fan :: ScopedFan, held :: a}

-- | The one request's fan-out whose breakdown names the task, else the requests whose do: none or several.
taskHolder :: RunState -> TaskId -> Either [TaskNo] (Holder Task)
taskHolder state task = case holders (`Fan.lookupTask` task) state of
    [one] -> Right one
    several -> Left (concatMap (toList . (.requests)) several)

{- | The request's fan-out holding this tasked child. A run id is its child's
alone, so no two hold it.
-}
childHolder :: RunState -> RunId -> Maybe (Holder Task)
childHolder state run = listToMaybe (holders (`Fan.childTask` run) state)

{- | The task of this id as its next event names it, beside the breakdown
of the one request's fan-out that holds it: refused as that event would be.
-}
taskRefIn :: RunState -> TaskId -> Either Refusal TaskRef
taskRefIn state task = do
    holder <- Bifunctor.first (NotOneHolder task) (taskHolder state task)
    Bifunctor.first FanRefused (Fan.taskRef (fanIn state.fans holder.fan) task)

-- | The task the child of this run id took, as its @spawned@ names it: none for an untasked or unknown child.
childRefIn :: RunState -> RunId -> Maybe TaskRef
childRefIn state run =
    childHolder state run >>= \holder -> Fan.childRef (fanIn state.fans holder.fan) run

{- | The breakdown a task added at seq @n@ joins: the one of the fan-out the
run is at, else the one it starts, at @n@.
-}
addedTo :: RunState -> Natural -> Natural
addedTo state n = maybe n (.seq) (currentFan state).breakdown

-- | Each fan-out the run's requests stand at whose state @holds@ finds something in, with the requests there.
holders :: (Fan -> Maybe a) -> RunState -> [Holder a]
holders holds state =
    [ Holder (fst <$> standing) (snd (NonEmpty.head standing)) scoped found
    | (scoped, standing) <-
        Map.toList
            ( Map.fromListWith
                (flip (<>))
                [ (scoped, (request, at) :| [])
                | (request, at) <- requestsAt state
                , Just scoped <- [fanAt at]
                ]
            )
    , Just found <- [holds (fanIn state.fans scoped)]
    ]

-- | Where each request stands: the one in focus first, then the waiting ones.
requestsAt :: RunState -> [(TaskNo, Node)]
requestsAt state =
    (state.focus, state.at)
        : [ (request, waitsAt suspension)
          | (request, suspension) <- Map.toList state.suspended
          ]

-- | The fan-out holding this run as an untasked child, if one does.
untaskedFan :: RunState -> RunId -> Maybe ScopedFan
untaskedFan state run =
    listToMaybe
        [ scoped
        | (scoped, fan) <- Map.toList state.fans
        , any
            (\childRun -> childRun.child.run == run && childRun.child.task == Untasked)
            fan.children
        ]

walked ::
    OpenGraph -> RunState -> Natural -> ScopePath -> AnyOutcome -> Either Refusal RunState
walked g state n scope outcome@(AnyOutcome _ some) = do
    let name = tookEvent scope outcome
    (from, edge) <-
        maybe (Left (NoEdge state.at name)) Right (edgeHere g state name)
    let effect = effects n scope outcome
    maybe (Right ()) (skipped state scope) effect.skip
    case (edge.to == At from, awaitedOpen g state from) of
        (False, open) | open > 0 -> Left (StillOpen open)
        _ -> Right ()
    meters <- spend g state (RecordedOutcome some)
    fans <- Bifunctor.first FanRefused (effect.fanned state.fans)
    let noted = fmap (noteProblems effect.problems) state.rounds
        rounds = enter g edge.back state.at edge.to noted
    -- A stay is no move: the questions asked here still are.
    Right
        state
            { at = edge.to
            , fuel = effect.level <|> state.fuel
            , rounds
            , fans
            , meters = kept g edge.to meters
            , askedHere = if edge.to == state.at then state.askedHere else []
            , onTarget = if effect.anew then Nothing else state.onTarget
            , focus = if effect.anew then nextTask state else state.focus
            , drafted = effect.draft <|> state.drafted
            , published = effect.pr <|> state.published
            , ticket = effect.written <|> state.ticket
            , latest =
                (.url) <$> effect.draft <|> effect.pr <|> effect.written <|> state.latest
            }

-- | The refusal of an edge into a step whose budget is used up.
usedUpAt :: OpenGraph -> RunState -> Edge Node -> Maybe Refusal
usedUpAt g state edge = case edge.to of
    At next ->
        listToMaybe
            [ OutOfBudget budget.cap most
            | (metered, budget@Budget {allows = Just most}) <- Map.toList (budgets g state)
            , metered.place == next
            , budget.spent >= most
            ]
    Out -> Nothing
    Exit -> Nothing

-- | The edge an event takes where the run is, and the state it leaves.
edgeHere :: OpenGraph -> RunState -> EventName -> Maybe (Place, Edge Node)
edgeHere g state name = case state.at of
    At place -> (place,) <$> (step g place name <|> lookup name (stuckExits g state place))
    Out -> Nothing
    Exit -> Nothing

{- | A step's outcome named in its flow's own scopes, as a flow's skill
names it (@gather.enough@, @gather/notes.done@), while the run sits inside
more scopes: the outcome of the step of the place's scope, when the named
scopes end it and only it has an edge here. A flow runs inline under a
scope with its skill unchanged so. An event an edge here takes as named is
that event, so a run outside every scope records each event as named.
-}
inScope :: OpenGraph -> RunState -> Event -> Event
inScope g state event = case (event, state.at) of
    (Took named outcome, At place)
        | scopeNames named `isSuffixOf` scopeNames place.scope
        , Nothing <- edgeHere g state (tookEvent named outcome)
        , Just _ <- edgeHere g state (tookEvent place.scope outcome) ->
            Took place.scope outcome
    _ -> event

{- | What an outcome changes besides the run's place: its problems join the
rounds it ends, and it may move a fan-out or name the run's PR or ticket.
-}
data Effect = Effect
    { fanned :: Map ScopedFan Fan -> Either Fan.Refusal (Map ScopedFan Fan)
    , problems :: Set Problem
    , draft :: Maybe DraftPr
    , pr :: Maybe Url
    , written :: Maybe Url
    , anew :: Bool
    -- ^ A new request starts: it has no target until one is named.
    , level :: Maybe Fuel
    -- ^ The run's Fuel from here on, as a 'Fuel' step sets it.
    , skip :: Maybe Skipping
    -- ^ The outcome skips a block, which the run's Fuel or its shape must allow.
    }

-- | Why a block may be skipped: a level that skips it, or a round on an existing PR, which keeps it.
data Skipping = ByLevel Name (PerFuel SkipWhen) | ByShape

{- | One arm per layer: a new layer breaks the build here, and a new outcome
in the layer's own match below. A fan-out's outcome moves the fan-out in the
outcome's scope.
-}
-- | @n@ is the outcome's seq.
effects :: Natural -> ScopePath -> AnyOutcome -> Effect
effects n scope (AnyOutcome l (SomeOutcome _ _ o)) = case l of
    GatherLayer -> none
    PlanLayer -> none
    BuildLayer -> none {draft = built o}
    ReviewLayer -> none {problems = reviewProblems o}
    ShipLayer ->
        let (found, url) = shipped o
         in none {problems = found, pr = url, skip = keeps o}
    TicketLayer -> none {written = ticketOf o}
    RequestLayer -> none {pr = openedPr o, anew = startsRequest o}
    FanLayer -> none {fanned = fanOutcome n scope o}
    PickLayer -> none
    FuelLayer -> none {level = fuelOutcome o, skip = skipOutcome o}
  where
    none =
        Effect
            { fanned = Right
            , problems = Set.empty
            , draft = Nothing
            , pr = Nothing
            , written = Nothing
            , anew = False
            , level = Nothing
            , skip = Nothing
            }

-- | The level a 'Fuel' step sets; a skip sets none.
fuelOutcome :: Outcome (s :: FuelStep) l -> Maybe Fuel
fuelOutcome = \case
    LevelSet level -> Just level
    Skipping _ -> Nothing
    Running _ -> Nothing

-- | The block a skip step skips, by the levels that may.
skipOutcome :: Outcome (s :: FuelStep) l -> Maybe Skipping
skipOutcome = \case
    Skipping (Skip name when) -> Just (ByLevel name when)
    LevelSet _ -> Nothing
    Running _ -> Nothing

-- | A @ready@ that leaves the PR as it is.
keeps :: Outcome (s :: ShipStep) l -> Maybe Skipping
keeps = \case
    ReadySkipped _ -> Just ByShape
    ReadyDone _ -> Nothing
    DescribeDone _ -> Nothing
    VisualDone _ -> Nothing
    SimplifyPrDone _ -> Nothing
    AwaitCiGreen _ -> Nothing
    AwaitCiRed _ _ -> Nothing
    FixPrDone _ -> Nothing

-- | The ticket written or edited.
ticketOf :: Outcome (s :: TicketStep) l -> Maybe Url
ticketOf = \case
    TicketWritten url -> Just url

-- | The PR an @open_pr@ names: a ship from it waits on that PR's CI.
openedPr :: Outcome (s :: RequestStep) l -> Maybe Url
openedPr = \case
    OpenPrDone url -> Just url
    OpenPlanDone _ -> Nothing
    OpenBranchDone _ -> Nothing
    DirectDone _ -> Nothing
    NextDone -> Nothing
    NextRequest -> Nothing

-- | The next request starts: the chief's loop goes round.
startsRequest :: Outcome (s :: RequestStep) l -> Bool
startsRequest = \case
    NextRequest -> True
    NextDone -> False
    OpenPlanDone _ -> False
    OpenBranchDone _ -> False
    OpenPrDone _ -> False
    DirectDone _ -> False

-- | The draft PR a draft names.
built :: Outcome (s :: BuildStep) l -> Maybe DraftPr
built = \case
    DraftDone pr -> Just pr
    ImplementDone _ -> Nothing
    RefactorDone _ -> Nothing

{- | A breakdown, logged at seq @n@, sets its fan-out's tasks; its end is
checked as it is written ('leaves').
-}
fanOutcome ::
    Natural ->
    ScopePath ->
    Outcome (s :: FanStep) l ->
    Map ScopedFan Fan ->
    Either Fan.Refusal (Map ScopedFan Fan)
fanOutcome n scope outcome fans = case outcome of
    BreakdownDone fan tasks ->
        (\fresh -> Map.insert (here fan) fresh fans)
            <$> Fan.broken n tasks (fanIn fans (here fan))
    MergeDone fan _ -> fans <$ Fan.closed (fanIn fans (here fan))
    MergeNextRound fan -> fans <$ Fan.closed (fanIn fans (here fan))
  where
    here = ScopedFan scope

{- | A skip the run may take: one its Fuel allows, @skip_refine@'s for a
plan settled without the user, and @ready@'s on a round on an existing PR
at every Fuel, which leaves the PR as it is, by the task's shape.
-}
skipped :: RunState -> ScopePath -> Skipping -> Either Refusal ()
skipped state scope = \case
    ByLevel name when
        | atFuel (fuelOf state) when /= Never || settledSkips state name -> Right ()
        | otherwise -> refused (nameText name)
    ByShape
        | onRound (shape state) -> Right ()
        | otherwise -> refused (stateNameText (stepName Ready))
  where
    refused block = Left (NotSkippable (Name (qualifyText scope block)))

{- | What the run does to its PR now: its request's target's, else its
start's. A branch's work opens its PR from that branch, or adopts the one open.
-}
shape :: RunState -> Shape
shape state = case (.target) <$> state.onTarget of
    Just (OnPr url) -> RoundOn url
    Just (OnBranch _) -> OwnPr
    Just (OnTicket _) -> principalShape state.start.principal
    Nothing -> principalShape state.start.principal

-- | The run is a round on a PR that exists already, named at init, by its parent's breakdown or by its request's target.
onRound :: Shape -> Bool
onRound = \case
    OwnPr -> False
    RoundOn _ -> True

{- | The run's plan needs no confirm from the user: its parent decided it, or
the request applies feedback to a target and no Design or Scope question opened.
-}
planSettled :: RunState -> Bool
planSettled state =
    principalPlan state.start.principal == ParentDecided
        || maybe False (not . (.designAsked)) state.onTarget

-- | Whether a settled plan skips the block: the refine passes, at any Fuel.
settledSkips :: RunState -> Name -> Bool
settledSkips state block = block == refineName && planSettled state

{- | A task added, or a round asked, at a fan-out's merge reopens the fan-out, where it is
spawned as any task is; the fan-out is left again once every task is settled.
-}
reopened :: OpenGraph -> RunState -> Either Refusal RunState
reopened g state = case state.at of
    At place
        | Just fan <- fanOf place.name
        , place.name == mergeName fan ->
            overridden g state (qualify place.scope (namedState fan))
    At _ -> Right state
    Out -> Right state
    Exit -> Right state

{- | A fan-out inside the scopes it sits in: two scoped copies of one
fan-out are two, each with its own tasks and children.
-}
data ScopedFan = ScopedFan {scope :: ScopePath, fan :: Name}
    deriving stock (Eq, Ord, Show)

-- | The fan-out the run is at: at its breakdown, its own state or its merge.
fanAt :: Node -> Maybe ScopedFan
fanAt = \case
    At place -> ScopedFan place.scope <$> fanOf place.name
    Out -> Nothing
    Exit -> Nothing

-- | A fan-out's tasks and children: empty before its breakdown.
fanIn :: Map ScopedFan Fan -> ScopedFan -> Fan
fanIn fans fan = Map.findWithDefault emptyFan fan fans

-- | The fan-out the run is at, and an empty one at any other state.
currentFan :: RunState -> Fan
currentFan state = maybe emptyFan (fanIn state.fans) (fanAt state.at)

{- | A child of a 'State.Flow.Combinator.parallel' is spawned while the run waits
for its group, at its 'State.Category.Flow.Await': the 10x spawns an
engineer once its task's dependencies merged.
-}
atAwait :: OpenGraph -> Node -> Either Refusal ()
atAwait g at = case at of
    At place | Just (Awaiting _) <- Map.lookup place g.groupStates -> Right ()
    _ -> Left (NoEdge at (fanEvent Spawns (nodeName at)))

-- | A child's hand-back stays where the graph has that fan-out event: at the fan-out.
atFan :: OpenGraph -> Node -> FanEvent -> Either Refusal ()
atFan g at event = case at of
    At place | Just Edge {arrow = Stay} <- step g place name -> Right ()
    _ -> Left (NoEdge at name)
  where
    name = fanEvent event (nodeName at)

{- | A question the run asks: its own question at a capped step, as the
interview's, spends the step's meter. Asking whether to go on spends none.
-}
asked :: OpenGraph -> RunState -> Asking -> Either Refusal RunState
asked g state asking
    | Set.member qid state.everAsked = Left (AskedTwice qid)
    | otherwise = do
        meters <- if spends then spend g state RecordedAsk else Right state.meters
        Right
            state
                { pending = state.pending <> [Pending asking ForTriage]
                , everAsked = Set.insert qid state.everAsked
                , meters
                , askedHere =
                    if spends && any usedUp (spentByAsk g state {meters})
                        then []
                        else state.askedHere <> [asking.question]
                , onTarget =
                    (\on -> on {designAsked = on.designAsked || opens asking.question.kind})
                        <$> state.onTarget
                }
  where
    qid = asking.question.qid
    opens = \case
        Ask.Design -> True
        Ask.Scope -> True
        Ask.Fact -> False
        Ask.Pick -> False
        Ask.Confirm -> False
        Ask.Security -> False
        Ask.Stuck -> False
    spends = case (asking.from, asking.question.kind) of
        (Itself, Ask.Stuck) -> False
        (Itself, _) -> True
        (Subagent _, _) -> False
        (ChildRun _, _) -> False

{- | An @extend@ grants again every budget the user may extend that holds
the run: their meters start afresh, and the run may ask whether to go on
once more.
-}
extended :: OpenGraph -> RunState -> Either Refusal RunState
extended g state = case extendable g state of
    [] -> Left NothingToExtend
    regranted ->
        Right state {meters = foldr Map.delete state.meters regranted, askedHere = []}

-- | The budgets holding the run that the user may extend: what an @extend@ grants again.
extendable :: OpenGraph -> RunState -> [Metered]
extendable g state = Map.keys (Map.filter (\budget -> extends budget.cap.atCap) (budgets g state))
  where
    extends = \case
        Extend -> True
        Refuse -> False
        Stop -> False

{- | What the event spends of each cap at the run's place. Past the cap at
the run's Fuel it is refused; a 'State.Category.Meter.PerGroup' cap the
kernel only counts.
-}
spend ::
    OpenGraph -> RunState -> Recorded -> Either Refusal (Map Metered Natural)
spend g state recorded = case state.at of
    At place ->
        foldM
            charge
            state.meters
            [(metered, cap) | (metered, cap) <- Map.toList g.caps, metered.place == place]
    Out -> Right state.meters
    Exit -> Right state.meters
  where
    charge meters (metered, cap) = do
        let before = Map.findWithDefault 0 metered meters
        spent <- case (spentBy cap.meter recorded, allowed (atFuel (fuelOf state) cap.limit)) of
            (0, _) -> Right before
            (cost, Just most) | before + cost > most -> Left (OutOfBudget cap most)
            (cost, _) -> Right (before + cost)
        Right (if spent == 0 then meters else Map.insert metered spent meters)

{- | At a group's 'State.Category.Flow.Await', the 'ledger''s open children
of its role, and a fan-out's tasks not yet settled with no child running:
the state is left only at none (an AND-join). None elsewhere.
-}
awaitedOpen :: OpenGraph -> RunState -> Place -> Natural
awaitedOpen g state place = case Map.lookup place g.groupStates of
    Just (Awaiting group) ->
        genericLength (filter ((== group.runner) . (.role)) (ledger g state))
            + sum
                [ genericLength (filter (`notElem` running fan) (Fan.unsettled fan))
                | Just name <- [fanNamed place.name]
                , let fan = fanIn state.fans (ScopedFan place.scope name)
                ]
    Just (Forking _) -> 0
    Nothing -> 0
  where
    running fan = [ref.task | childRun <- Fan.running fan, Tasked ref <- [childRun.child.task]]

{- | The capped forks whose budget holds the run: a forked child's
hand-back is recorded at one, in its scope, wherever the run is in the
fork's loop. Outside it, its role's hand-back is the step's there, as a
researcher also simplifies the plan.
-}
forks :: OpenGraph -> RunState -> [Metered]
forks g state =
    [ metered
    | metered <- Map.keys (budgets g state)
    , Just (Forking _) <- [Map.lookup metered.place g.groupStates]
    ]

-- | A cap's budget as the run stands: what it spent, and what the run's Fuel allows.
data Budget = Budget {cap :: Cap, spent :: Natural, allows :: Maybe Natural}
    deriving stock (Eq, Show)

-- | Nothing is left of it: the next spend is refused.
usedUp :: Budget -> Bool
usedUp budget = maybe False (budget.spent >=) budget.allows

{- | The budgets that hold the run: of each cap whose innermost loop holds
its place, so the run spends them in this round.
-}
budgets :: OpenGraph -> RunState -> Map Metered Budget
budgets g state =
    Map.mapWithKey
        budgetOf
        (Map.filterWithKey (\metered _ -> heldIn g metered.place state.at) g.caps)
  where
    budgetOf metered cap =
        Budget
            { cap
            , spent = Map.findWithDefault 0 metered state.meters
            , allows = allowed (atFuel (fuelOf state) cap.limit)
            }

-- | The budgets at the run's state that a question spends.
spentByAsk :: OpenGraph -> RunState -> [Budget]
spentByAsk g state =
    [ budget
    | (metered, budget) <- Map.toList (budgets g state)
    , At metered.place == state.at
    , spentBy budget.cap.meter RecordedAsk > 0
    ]

-- | The ledger after a move: a meter's spend lasts while the run stays in the innermost loop around its step's state.
kept :: OpenGraph -> Node -> Map Metered Natural -> Map Metered Natural
kept g to = Map.filterWithKey (\metered _ -> heldIn g metered.place to)

{- | The node is in the innermost loop around the capped step's place, or the
step is in no loop: the run is still in the rounds the step's meter counts.
-}
heldIn :: OpenGraph -> Place -> Node -> Bool
heldIn g place node = case (innermost g place, node) of
    (Nothing, _) -> True
    (Just loop, At at) -> Set.member at loop.body
    (Just _, Out) -> False
    (Just _, Exit) -> False

retagged :: RunState -> QId -> Either Refusal RunState
retagged state qid = do
    question <- (.question) <$> forTriage qid state.pending
    let raised pending =
            pending
                { asking = pending.asking {question = Question qid Security question.text}
                }
    Right state {pending = adjust qid raised state.pending}

ruledOn :: RunState -> QId -> Proposal -> Either Refusal RunState
ruledOn state qid proposal = do
    asking <- forTriage qid state.pending
    ruling <-
        Bifunctor.first
            NotAllowed
            ( Ask.rule
                (Role.rungAt state.start.flow asking.step)
                asking.question.kind
                asking.question
                proposal
            )
    Right
        state {pending = close qid state.pending, rulings = state.rulings <> [ruling]}

forwarded :: RunState -> QId -> Above -> Either Refusal RunState
forwarded state qid to = do
    asking <- forTriage qid state.pending
    void
        ( Bifunctor.first
            NotAllowed
            ( Ask.pass
                (Role.rungAt state.start.flow asking.step)
                asking.question.kind
                asking.question
            )
        )
    fromAbove state.start.principal to
    Right
        state
            { pending = adjust qid (\pending -> pending {waits = ForAnswer}) state.pending
            }

-- | 'append' takes the answer the run holds again as no news; another is refused.
answered :: RunState -> QId -> Reply -> Above -> Either Refusal RunState
answered state qid reply by = case heldAnswer state qid of
    Just earlier -> Left (AnsweredOtherwise qid earlier)
    Nothing -> firstAnswer state qid reply by

-- | Only a forwarded question is answered from above: a parked one was forwarded before it was parked ('parked').
firstAnswer :: RunState -> QId -> Reply -> Above -> Either Refusal RunState
firstAnswer state qid reply by = do
    asking <- forwardedAsking qid state.pending
    fromAbove state.start.principal by
    Right
        state
            { pending = close qid state.pending
            , answers = state.answers <> [Answer asking.question reply asking.step]
            }

{- | A forwarded question parked, or parked again with another reason: it
stays open. One still in triage is refused like its answer, so a park never
lets a kind the run must answer itself be answered from above ('Ask.pass').
-}
parked :: RunState -> QId -> OneLine -> Either Refusal RunState
parked state qid why = do
    _ <- forwardedAsking qid state.pending
    Right
        state
            { pending = adjust qid (\pending -> pending {waits = ForLater why}) state.pending
            }

-- | The question this run forwarded, parked or not, for its answer to come down.
forwardedAsking :: QId -> [Pending] -> Either Refusal Asking
forwardedAsking qid pending =
    pendingOf qid pending >>= \open -> case open.waits of
        ForTriage -> Left (NotForwarded qid)
        ForAnswer -> Right open.asking
        ForLater _ -> Right open.asking

-- | The question this run has yet to rule on or forward.
forTriage :: QId -> [Pending] -> Either Refusal Asking
forTriage qid pending =
    pendingOf qid pending >>= \open -> case open.waits of
        ForTriage -> Right open.asking
        ForAnswer -> Left (AlreadyForwarded qid)
        ForLater _ -> Left (IsParked qid)

pendingOf :: QId -> [Pending] -> Either Refusal Pending
pendingOf qid = maybe (Left (NotPending qid)) Right . find ((== qid) . pendingId)

adjust :: QId -> (Pending -> Pending) -> [Pending] -> [Pending]
adjust qid change =
    map (\pending -> if pendingId pending == qid then change pending else pending)

close :: QId -> [Pending] -> [Pending]
close qid = filter ((/= qid) . pendingId)

pendingId :: Pending -> QId
pendingId pending = pending.asking.question.qid

-- | The answer from above the run holds to this question, if it was answered.
heldAnswer :: RunState -> QId -> Maybe Reply
heldAnswer state qid = (.given) <$> find ((== qid) . (.about.qid)) state.answers

-- | Each question the run ruled on or had answered from above, with its kind and answer: a ruling's is an option chosen.
given :: RunState -> [(QId, Kind, Reply)]
given state =
    [ (ruling.qid, ruling.kind, Chose (oneLineText ruling.proposal.answer))
    | ruling <- state.rulings
    ]
        <> [(answer.about.qid, answer.about.kind, answer.given) | answer <- state.answers]

-- | The question pending under this id, if one is.
pendingAt :: RunState -> QId -> Maybe Pending
pendingAt state qid = find ((== qid) . pendingId) state.pending

-- | Why the question is parked, if it is.
parkedFor :: RunState -> QId -> Maybe OneLine
parkedFor state qid =
    pendingAt state qid >>= \pending -> case pending.waits of
        ForLater why -> Just why
        ForTriage -> Nothing
        ForAnswer -> Nothing

{- | A parked task's children wait on no answer: the questions they asked
leave the pending ones, as no child of it will read an answer.
-}
unaskedBy :: Fan -> TaskId -> RunState -> RunState
unaskedBy fan task state = state {pending = filter (not . byChild . (.asking.from)) state.pending}
  where
    children = map (.child.run) (Fan.childrenOf fan task)
    byChild = \case
        ChildRun run -> run `elem` children
        Itself -> False
        Subagent _ -> False

-- | The children whose question is still open, in triage or with the user: none of their tasks is retried.
askingChildren :: RunState -> [RunId]
askingChildren state = [run | pending <- state.pending, ChildRun run <- [pending.asking.from]]

-- | The state a question asked now is asked at, inside its scopes; past the end, the port's name.
askedAt :: RunState -> StateName
askedAt state = nodeName state.at

-- | A node's state, inside its scopes; past the end, the port's name.
nodeName :: Node -> StateName
nodeName = \case
    At place -> placeName place
    Out -> StateName "out"
    Exit -> StateName "exit"

-- | The run stopped, or left its flow.
over :: RunState -> Bool
over state = case (state.stopped, state.at) of
    (Just _, _) -> True
    (Nothing, At _) -> False
    (Nothing, Out) -> True
    (Nothing, Exit) -> True

-- | Questions go up to, and answers come down from, whoever started the run.
fromAbove :: Principal -> Above -> Either Refusal ()
fromAbove principal named
    | named == deliver principal = Right ()
    | otherwise = Left (NotAbove named)

overridden :: OpenGraph -> RunState -> StateName -> Either Refusal RunState
overridden g state target = case Set.toList (Set.filter (\place -> placeName place == target) (places g)) of
    [place] -> Right (movedTo g state (At place))
    _ -> Left (NoSingleState target)

-- | The run moved to the node off the flow's edges, as an override or a new request moves it.
movedTo :: OpenGraph -> RunState -> Node -> RunState
movedTo g state to =
    state
        { at = to
        , rounds = enter g Nothing state.at to state.rounds
        , meters = kept g to state.meters
        , askedHere = []
        }

{- | A run whose flow switches requests, the chief's, going on: its flow
handles 'FocusE' ("State.Flow.Role.Chief").
-}
focusable :: RunState -> Either Refusal ()
focusable state = case (state.start.flow, over state) of
    (ChiefFlow, False) -> Right ()
    (ChiefFlow, True) -> Left NoFocus
    (EngineerFlow, _) -> Left NoFocus
    (TenXFlow, _) -> Left NoFocus
    (ArchitectFlow, _) -> Left NoFocus

{- | The request in focus waits where it stands, its own open questions
waiting apart, a forwarded one parked: a new request opens.
-}
suspends ::
    OpenGraph -> RunState -> TaskNo -> OneLine -> Either Refusal RunState
suspends g state task summary
    | task /= state.focus = Left (NotInFocus task)
    | otherwise =
        Right
            (opened g state)
                { suspended =
                    Map.insert
                        task
                        (Suspension (positionOf state) summary [(pendingId p, p.waits) | p <- own])
                        state.suspended
                , pending = map park state.pending
                }
  where
    own = filter ((== Itself) . (.asking.from)) state.pending
    park p = case (p.asking.from, p.waits) of
        (Itself, ForAnswer) -> p {waits = ForLater (flattened ("suspended " <> taskNoText task))}
        (Itself, ForTriage) -> p
        (Itself, ForLater _) -> p
        (Subagent _, _) -> p
        (ChildRun _, _) -> p

{- | Focus on the waiting request, where it stood, its questions waiting as
they did. The request in focus, untouched or finished, is dropped: one
underway is suspended first.
-}
focuses :: OpenGraph -> RunState -> TaskNo -> Either Refusal RunState
focuses g state task = case (Map.lookup task state.suspended, stage g state) of
    (Nothing, _) -> Left (NotSuspended task)
    (Just _, Underway) -> Left (FocusRecorded state.focus)
    (Just suspension, Untouched) -> Right (resumed suspension)
    (Just suspension, Finished) -> Right (resumed suspension)
  where
    resumed (Suspension position _ asks) =
        (placed g position state)
            { focus = task
            , suspended = Map.delete task state.suspended
            , pending =
                map
                    (\p -> maybe p (\waits -> p {waits}) (lookup (pendingId p) asks))
                    state.pending
            }

-- | A new request in focus, at the flow's start, numbered past every request still open.
opened :: OpenGraph -> RunState -> RunState
opened g state = (movedTo g state (At g.inPort)) {onTarget = Nothing, focus = nextTask state}

nextTask :: RunState -> TaskNo
nextTask state = case maximum (state.focus : Map.keys state.suspended) of
    TaskNo n -> TaskNo (n + 1)

{- | How far the chief's request in focus went, read off the cursor, never
stored: a turn away loses nothing of one untouched or finished.
-}
data Stage
    = -- | At the flow's start, its target unnamed: it recorded nothing.
      Untouched
    | -- | Past its start and not yet at @next@: a turn away suspends it.
      Underway
    | -- | At @next@: its route ran to the end, and the next request is the run's to take.
      Finished
    deriving stock (Eq, Show)

stage :: OpenGraph -> RunState -> Stage
stage g state
    | state.at == At g.inPort && isNothing state.onTarget = Untouched
    | nodeName state.at == stepName Request.Next = Finished
    | otherwise = Underway

positionOf :: RunState -> Position
positionOf state =
    Position
        state.at
        state.fuel
        state.rounds
        state.meters
        state.askedHere
        state.onTarget
        state.latest

{- | The run at the waiting request's position. A meter whose loop holds the
request's start counts across requests, as the Requests cap does: it keeps
its live spend, so the requests finished while this one waited still count.
-}
placed :: OpenGraph -> Position -> RunState -> RunState
placed g (Position at fuel rounds meters askedHere onTarget latest) state =
    state
        { at
        , fuel
        , rounds
        , meters =
            Map.union
                (Map.filterWithKey (const . acrossRequests) state.meters)
                (Map.filterWithKey (\metered _ -> not (acrossRequests metered)) meters)
        , askedHere
        , onTarget
        , latest
        }
  where
    acrossRequests metered = heldIn g metered.place (At g.inPort)

-- | The questions the waiting requests hold: none waits on the request in focus.
suspendedAsks :: RunState -> [QId]
suspendedAsks state = [qid | suspension <- Map.elems state.suspended, (qid, _) <- suspension.asks]

{- | The rounds after a move from one node to another. A loop's own back
edge starts its next round; one entered from outside, or restarted by an
enclosing loop's next round, starts at round one; one left is closed. The
rounds bound nothing: they are the history the stuck rule reads.
-}
enter ::
    OpenGraph ->
    Maybe Name ->
    Node ->
    Node ->
    Map Name (NonEmpty Round) ->
    Map Name (NonEmpty Round)
enter g back from to current = Map.mapMaybeWithKey around g.loops
  where
    inside loop = \case
        At place -> Set.member place loop.body
        Out -> False
        Exit -> False
    restarts loop = case back of
        Just outer ->
            maybe
                False
                (\outerAt -> loop.body `Set.isProperSubsetOf` outerAt.body)
                (Map.lookup outer g.loops)
        Nothing -> False
    around name loop = case (inside loop to, Map.lookup name current) of
        (False, _) -> Nothing
        (True, Just done) | back == Just name -> Just (done <> firstRound)
        (True, Just done) | inside loop from && not (restarts loop) -> Just done
        (True, _) -> Just firstRound

firstRound :: NonEmpty Round
firstRound = Round Set.empty :| []

noteProblems :: Set Problem -> NonEmpty Round -> NonEmpty Round
noteProblems new = lastRound (\(Round problems) -> Round (problems <> new))

lastRound :: (Round -> Round) -> NonEmpty Round -> NonEmpty Round
lastRound change rounds = case NonEmpty.reverse rounds of
    latest :| before -> NonEmpty.reverse (change latest :| before)

-- | The rows a pick leaves to fix and the requirements it judged not met.
reviewProblems :: Outcome (s :: ReviewStep) l -> Set Problem
reviewProblems = \case
    PickFinal picks -> picked picks
    PickLoop picks -> picked picks
    ReviewClean _ -> Set.empty
    ReviewRows _ -> Set.empty
    FixDone _ -> Set.empty
    ReReviewClean _ -> Set.empty
    ReReviewRows _ -> Set.empty
  where
    picked picks =
        Set.map Row picks.rows
            <> Set.map Unmet (Map.keysSet (Map.filter (== NotMet) picks.verdicts))

-- | A red CI's failing checks, and the PR a ready, or a skipped one, leaves.
shipped :: Outcome (s :: ShipStep) l -> (Set Problem, Maybe Url)
shipped = \case
    AwaitCiRed _ failing -> (Set.fromList (map Failing (NonEmpty.toList failing)), Nothing)
    ReadyDone url -> (Set.empty, Just url)
    ReadySkipped url -> (Set.empty, Just url)
    DescribeDone _ -> (Set.empty, Nothing)
    VisualDone _ -> (Set.empty, Nothing)
    SimplifyPrDone _ -> (Set.empty, Nothing)
    AwaitCiGreen _ -> (Set.empty, Nothing)
    FixPrDone _ -> (Set.empty, Nothing)

-- | Balanced until recorded, as a brief with no @Fuel@ line reads.
fuelOf :: RunState -> Fuel
fuelOf state = fromMaybe Balanced state.fuel

-- | A loop making no progress: these problems were in both of its last two rounds.
data Stuck = Stuck {loop :: Name, same :: Set Problem}
    deriving stock (Eq, Show)

{- | Once a Stuck question was asked in a loop's body, the edges that leave
the loop from its entry, which the run may take from where it is: a stuck
review loop ends by @pick.final@ at @fix@ without an override. None at the
entry itself, whose edges are its own, and none from an entry that awaits
something outside the run: a stuck CI loop never claims @await_ci.green@.
-}
stuckExits :: OpenGraph -> RunState -> Place -> [(EventName, Edge Node)]
stuckExits g state place = case innermost g place of
    Just loop
        | Ask.Stuck `elem` map (.kind) state.askedHere
            && loop.entry /= place
            && not (awaits loop.entry) ->
            [ (event, edge)
            | (event, edge) <- outOf loop.entry g.edges
            , not (inBody loop edge.to)
            ]
    _ -> []
  where
    inBody loop = \case
        At to -> Set.member to loop.body
        Out -> False
        Exit -> False
    awaits entry = case stepNamed entry.name of
        Just (AnyStep _ (SomeStep s)) -> stepAwaits s
        Nothing -> False

{- | Only the last two rounds, and only in a row, as #351 decided. It misses
rows alternating A, B, A, B on purpose: no two rounds in a row share a row, and
the loop's capped step ends it.
-}
stuck :: RunState -> [Stuck]
stuck state =
    [ Stuck loop same
    | (loop, rounds) <- Map.toList state.rounds
    , current : previous : _ <- [reverse (NonEmpty.toList rounds)]
    , let same = Set.intersection previous.found current.found
    , not (Set.null same)
    ]
