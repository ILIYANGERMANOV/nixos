{- | What a run knows is a fold over its log (#351 section 7). A step event
moves the run along one edge of the flow's graph, found by "State.Category.Path", so a
log the fold accepts is a path of @Run(F)@ (law Trace soundness). Every loop
has fuel and the stuck guard short-circuits it (law Bounded).

A question stays pending until this run rules on it, the answer comes down
after a forward, or the run stops. Each is checked against the run's own row
of 'State.Run.Ask.authority', the row of the role its flow runs.
-}
module State.Run.Fold (
    RunState (..),
    Round (..),
    Problem (..),
    Pending (..),
    Answer (..),
    Waits (..),
    Refusal (..),
    Append (..),
    replay,
    runStart,
    fold,
    append,
    mode,
    Stuck (..),
    stuck,
    budget,
    roundOnly,
    flowRole,
    nextQId,
    askingChildren,
    askedAt,
) where

import Control.Applicative ((<|>))
import Control.Monad (foldM, void)
import Data.Bifunctor qualified as Bifunctor
import Data.Foldable (for_, traverse_)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Numeric.Natural (Natural)
import State.Category.Flow (FanEvent (..), LoopId, OptId, fanEvent)
import State.Category.Graph (Arrow (..), Edge (..), LoopAt (..), Node (..), OpenGraph (..), Place (..), places)
import State.Category.Mode (Cfg (..), Mode (..), Quality (..), Size (..), SkipWhen (..), cfg)
import State.Category.Path (step)
import State.Category.Step (EventName, Outcome, SomeOutcome (..))
import State.Run.Ask (Above, Kind (Security), OneLine, Principal, Proposal, QId (..), Question (..), Role (..), Ruling, deliver)
import State.Run.Ask qualified as Ask
import State.Run.Event (AgentRole, Asker (..), Asking (..), Check, DraftPr, Envelope (..), Event (..), EventId, FlowName (..), Judgement (..), Label, Note, Picks (..), Requirement, RunId, Start (..), StateName (..), Stop, Url, eventId)
import State.Run.Fan (Fan, emptyFan)
import State.Run.Fan qualified as Fan
import State.Step.Build (BuildStep, Outcome (..))
import State.Step.Catalog (AnyOutcome (..), Layer (..), outcomeEvent)
import State.Step.Fan (FanStep, Outcome (..))
import State.Step.Review (Outcome (..), ReviewStep)
import State.Step.Ship (Outcome (..), ShipStep)

data RunState = RunState
    { run :: RunId
    , start :: Start
    , at :: Node
    , quality :: Maybe Quality
    -- ^ 'Nothing' until recorded: 'mode' reads the defaults meanwhile.
    , size :: Maybe Size
    , rounds :: Map LoopId (NonEmpty Round)
    -- ^ The rounds so far of each loop the run is inside, oldest first.
    , seen :: Set EventId
    , stopped :: Maybe Stop
    , refused :: Maybe Note
    -- ^ The refusal logged last, until the next event.
    , pending :: [Pending]
    -- ^ Oldest first.
    , everAsked :: Set QId
    -- ^ Every question asked, open or closed: a retried ask is refused, so it is never ruled twice.
    , askedHere :: [Kind]
    -- ^ The kinds asked since the run last moved, oldest first: advice asks a step's question once.
    , rulings :: [Ruling]
    -- ^ Every ruling the run made, oldest first: @show@ and the hand-back list them (law Audit).
    , answers :: [Answer]
    -- ^ Every forwarded question answered from above, oldest first: @show@ lists them.
    , drafted :: Maybe DraftPr
    -- ^ The draft PR the run recorded last: its url when GitHub is not read.
    , untriaged :: [(AgentRole, OneLine)]
    -- ^ The workers' hand-backs the run has yet to ask as its own question, oldest first.
    , published :: Maybe Url
    {- ^ The PR @ready@ recorded last: the url of a run that skipped its draft
    by override, as a retry does, when GitHub is not read.
    -}
    , fanOut :: Fan
    -- ^ The 10x's tasks and child runs: empty in a run with no fan-out.
    }
    deriving stock (Eq, Show)

-- | A forwarded question and the answer that came down for it.
data Answer = Answer {about :: Question, given :: Text}
    deriving stock (Eq, Show)

-- | A question asked and not yet ruled on, answered or ended by a stop.
data Pending = Pending {asking :: Asking, waits :: Waits}
    deriving stock (Eq, Show)

data Waits
    = -- | For this run to rule on it or forward it.
      ForTriage
    | -- | Forwarded, for the answer to come down.
      ForAnswer
    deriving stock (Eq, Show)

-- | What went wrong in one round of a loop: the stuck guard compares two.
newtype Round = Round (Set Problem)
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
    | -- | The mode never skips this step.
      NotSkippable OptId
    | -- | Another round would pass the loop's fuel.
      OutOfFuel LoopId Natural
    | QualitySetOnce Quality
    | -- | Only @grew@ changes the size.
      SizeSetOnce Size
    | -- | An override names a state the flow does not have, or more than one.
      NoSingleState StateName
    | -- | The question was asked already, whether pending or closed.
      AskedTwice QId
    | NotPending QId
    | -- | Forwarded already: only its answer is left.
      AlreadyForwarded QId
    | -- | An answer to a question the run never forwarded.
      NotForwarded QId
    | -- | The run's row of 'State.Run.Ask.authority' does not allow it.
      NotAllowed Ask.Refusal
    | -- | A forward or answer naming another than whoever started the run.
      NotAbove Above
    | FanRefused Fan.Refusal
    deriving stock (Eq, Show)

-- | An id already in the log is not appended twice: the append is a no-op.
data Append = Appended RunState | AlreadyLogged
    deriving stock (Eq, Show)

-- | A whole log, from its @started@ line.
replay :: OpenGraph -> NonEmpty Envelope -> Either Refusal RunState
replay g (first :| rest) = do
    state <- begin g first
    fold g state rest

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
    | otherwise = do
        next <- applyEvent g state envelope.event
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
                , quality = Nothing
                , size = Nothing
                , rounds = Map.mapMaybe (\loop -> if Set.member g.inPort loop.body then Just firstRound else Nothing) g.loops
                , seen = Set.singleton (eventId envelope)
                , stopped = Nothing
                , refused = Nothing
                , pending = []
                , everAsked = Set.empty
                , askedHere = []
                , rulings = []
                , answers = []
                , drafted = Nothing
                , published = Nothing
                , untriaged = []
                , fanOut = emptyFan
                }

-- | The run an event starts: a log's first line must start one.
runStart :: Event -> Maybe Start
runStart = \case
    Started start -> Just start
    QualitySet _ -> Nothing
    SizeSet _ -> Nothing
    Grew _ -> Nothing
    Took _ -> Nothing
    Stopped _ -> Nothing
    Overridden _ _ -> Nothing
    Refused _ -> Nothing
    Asked _ -> Nothing
    RetaggedSecurity _ -> Nothing
    RuledOn _ _ -> Nothing
    Forwarded _ _ -> Nothing
    Answered {} -> Nothing
    Spawning _ -> Nothing
    Spawned _ -> Nothing
    Resumed _ -> Nothing
    HandedBack _ _ -> Nothing
    TaskMoved _ _ -> Nothing
    Held _ _ -> Nothing
    ActedOn _ _ -> Nothing
    WorkerHandedBack _ _ -> Nothing

-- | A refusal is logged whatever the run's state; anything else needs a run going.
applyEvent :: OpenGraph -> RunState -> Event -> Either Refusal RunState
applyEvent g state = \case
    Refused note -> Right state {refused = Just note}
    Started _ -> going (Left StartedTwice)
    QualitySet quality -> going $ case state.quality of
        Just set | set /= quality -> Left (QualitySetOnce set)
        _ -> Right state {quality = Just quality}
    SizeSet size -> going $ case state.size of
        Just set | set /= size -> Left (SizeSetOnce set)
        _ -> Right state {size = Just size}
    Grew _ -> going (Right state {size = Just Normal})
    Took outcome -> going (took g state outcome)
    Stopped stop -> going (Right state {stopped = Just stop, pending = []})
    Overridden name _ -> going (overridden g state name)
    Asked asking -> going (fromChild asking.from <$> asked state asking)
    RetaggedSecurity qid -> going (retagged state qid)
    RuledOn qid proposal -> going (ruledOn state qid proposal)
    Forwarded qid to -> going (forwarded state qid to)
    Answered qid answer by -> going (answered state qid answer by)
    Spawning task -> going (inFan (Fan.spawning (askingChildren state) task))
    Spawned child -> going (atFan g state Spawns >> inFan (Fan.spawned (askingChildren state) child))
    Resumed child -> going (inFan (Fan.resumed child))
    HandedBack child said -> going (atFan g state HandsBack >> inFan (Fan.handedBack child said))
    TaskMoved task moved -> going (inFan (Fan.moved task moved))
    Held task url -> going (inFan (Fan.held task url))
    ActedOn task url -> going (inFan (Fan.actedOn task url))
    WorkerHandedBack role line -> going (Right state {untriaged = state.untriaged <> [(role, line)]})
  where
    -- A question asked from a stopped child is its stop, triaged.
    fromChild from after = case from of
        ChildRun child -> after {fanOut = Fan.triaged child after.fanOut}
        Itself -> after
        -- A question asked from a worker triages its oldest hand-back.
        Subagent role -> after {untriaged = triagedBy role after.untriaged}
    inFan change = (\fanOut -> state {fanOut}) <$> Bifunctor.first FanRefused (change state.fanOut)
    going next = case state.stopped of
        Just stop -> Left (AfterStop stop)
        Nothing -> (\moved -> moved {refused = Nothing}) <$> next

-- | The worker's oldest hand-back gone, once the run asked it as a question.
triagedBy :: AgentRole -> [(AgentRole, OneLine)] -> [(AgentRole, OneLine)]
triagedBy role untriaged = case break ((== role) . fst) untriaged of
    (before, _ : after) -> before <> after
    (before, []) -> before

-- | Moves along the outcome's edge, after the outcome's problems join the rounds it ends.
took :: OpenGraph -> RunState -> AnyOutcome -> Either Refusal RunState
took g state outcome = do
    let name = outcomeEvent outcome
    edge <- maybe (Left (NoEdge state.at name)) Right $ case state.at of
        At place -> step g place name
        Out -> Nothing
        Exit -> Nothing
    case edge.arrow of
        Skip optId | (cfg (mode state)).skip optId == Never -> Left (NotSkippable optId)
        Skip _ -> Right ()
        Along _ -> Right ()
        Stay -> Right ()
    let effect = effects outcome
    fanOut <- Bifunctor.first FanRefused (effect.fanned state.fanOut)
    let noted = fmap (noteProblems effect.problems) state.rounds
    rounds <- enter g (cfg (mode state)).fuel edge.back state.at edge.to noted
    for_ (roundOnly g edge.to) $ \loopId ->
        traverse_ (nextRound loopId ((cfg (mode state)).fuel loopId)) (Map.lookup loopId rounds)
    Right state {at = edge.to, rounds, fanOut, askedHere = [], drafted = effect.draft <|> state.drafted, published = effect.pr <|> state.published}

{- | What an outcome changes besides the run's place: its problems join the
rounds it ends, and it may move the fan-out or name the run's PR.
-}
data Effect = Effect
    { fanned :: Fan -> Either Fan.Refusal Fan
    , problems :: Set Problem
    , draft :: Maybe DraftPr
    , pr :: Maybe Url
    }

{- | One arm per layer: a new layer breaks the build here, and a new outcome
in the layer's own match below.
-}
effects :: AnyOutcome -> Effect
effects (AnyOutcome l (SomeOutcome _ _ o)) = case l of
    GatherLayer -> none
    PlanLayer -> none
    BuildLayer -> none {draft = built o}
    ReviewLayer -> none {problems = reviewProblems o}
    ShipLayer -> let (found, url) = shipped o in none {problems = found, pr = url}
    FanLayer -> none {fanned = fanOutcome o}
  where
    none = Effect {fanned = Right, problems = Set.empty, draft = Nothing, pr = Nothing}

-- | The draft PR a draft names.
built :: Outcome (s :: BuildStep) l -> Maybe DraftPr
built = \case
    DraftDone pr -> Just pr
    ImplementDone _ -> Nothing
    RefactorDone _ -> Nothing
    RefactorSkipped _ -> Nothing

-- | A breakdown sets the fan-out's tasks; the fan-out is left once they are settled.
fanOutcome :: Outcome (s :: FanStep) l -> Fan -> Either Fan.Refusal Fan
fanOutcome outcome fan = case outcome of
    BreakdownDone tasks -> Right (Fan.broken tasks fan)
    FanDone _ -> fan <$ Fan.leave fan
    MergeDone _ -> fan <$ Fan.closed fan

-- | A child's spawn or hand-back stays where the graph has that fan-out event: at the fan-out.
atFan :: OpenGraph -> RunState -> FanEvent -> Either Refusal ()
atFan g state event = case state.at of
    At place | Just Edge {arrow = Stay} <- step g place name -> Right ()
    _ -> Left (NoEdge state.at name)
  where
    name = fanEvent event (askedAt state)

{- | The loop whose next round every way out of this node starts, as @fix@ in
the review loop. A move there with no round left is refused before the work
it starts: the run is still where the loop's exit is open (#360's fold).
-}
roundOnly :: OpenGraph -> Node -> Maybe LoopId
roundOnly g = \case
    At place -> case [edge.back | ((from, _), edge) <- Map.toList g.edges, from == place] of
        Just loopId : backs | all (== Just loopId) backs -> Just loopId
        _ -> Nothing
    Out -> Nothing
    Exit -> Nothing

asked :: RunState -> Asking -> Either Refusal RunState
asked state asking
    | Set.member qid state.everAsked = Left (AskedTwice qid)
    | otherwise =
        Right
            state
                { pending = state.pending <> [Pending asking ForTriage]
                , everAsked = Set.insert qid state.everAsked
                , askedHere = state.askedHere <> [asking.question.kind]
                }
  where
    qid = asking.question.qid

retagged :: RunState -> QId -> Either Refusal RunState
retagged state qid = do
    question <- forTriage qid state.pending
    let raised pending = pending {asking = pending.asking {question = Question qid Security question.text}}
    Right state {pending = adjust qid raised state.pending}

ruledOn :: RunState -> QId -> Proposal -> Either Refusal RunState
ruledOn state qid proposal = do
    question <- forTriage qid state.pending
    ruling <- Bifunctor.first NotAllowed (Ask.rule (flowRole state.start.flow) question.kind question proposal)
    Right state {pending = close qid state.pending, rulings = state.rulings <> [ruling]}

forwarded :: RunState -> QId -> Above -> Either Refusal RunState
forwarded state qid to = do
    question <- forTriage qid state.pending
    void (Bifunctor.first NotAllowed (Ask.pass (flowRole state.start.flow) question.kind question))
    fromAbove state.start.principal to
    Right state {pending = adjust qid (\pending -> pending {waits = ForAnswer}) state.pending}

answered :: RunState -> QId -> Text -> Above -> Either Refusal RunState
answered state qid answer by = do
    pending <- pendingOf qid state.pending
    case pending.waits of
        ForTriage -> Left (NotForwarded qid)
        ForAnswer -> Right ()
    fromAbove state.start.principal by
    Right state {pending = close qid state.pending, answers = state.answers <> [Answer pending.asking.question answer]}

-- | The question this run has yet to rule on or forward.
forTriage :: QId -> [Pending] -> Either Refusal Question
forTriage qid pending =
    pendingOf qid pending >>= \open -> case open.waits of
        ForTriage -> Right open.asking.question
        ForAnswer -> Left (AlreadyForwarded qid)

pendingOf :: QId -> [Pending] -> Either Refusal Pending
pendingOf qid = maybe (Left (NotPending qid)) Right . find ((== qid) . pendingId)

adjust :: QId -> (Pending -> Pending) -> [Pending] -> [Pending]
adjust qid change = map (\pending -> if pendingId pending == qid then change pending else pending)

close :: QId -> [Pending] -> [Pending]
close qid = filter ((/= qid) . pendingId)

pendingId :: Pending -> QId
pendingId pending = pending.asking.question.qid

-- | The children whose question is still open, in triage or with the user: none of their tasks is retried.
askingChildren :: RunState -> [RunId]
askingChildren state = [run | pending <- state.pending, ChildRun run <- [pending.asking.from]]

-- | The id of the run's next own question: one past the highest it asked.
nextQId :: RunState -> QId
nextQId state = QId state.run (1 + maximum (0 : [n | QId asker n <- Set.toList state.everAsked, asker == state.run]))

-- | The state a question asked now is asked at; past the end, the port's name.
askedAt :: RunState -> StateName
askedAt state = case state.at of
    At place -> place.name
    Out -> StateName "out"
    Exit -> StateName "exit"

-- | Questions go up to, and answers come down from, whoever started the run.
fromAbove :: Principal -> Above -> Either Refusal ()
fromAbove principal named
    | named == deliver principal = Right ()
    | otherwise = Left (NotAbove named)

-- | The rung of the chain the run's flow stands on.
flowRole :: FlowName -> Role
flowRole = \case
    EngineerFlow -> Engineer
    TenXFlow -> TenX

overridden :: OpenGraph -> RunState -> StateName -> Either Refusal RunState
overridden g state target = case Set.toList (Set.filter (\place -> place.name == target) (places g)) of
    [place] -> do
        rounds <- enter g (cfg (mode state)).fuel Nothing state.at (At place) state.rounds
        Right state {at = At place, rounds, askedHere = []}
    _ -> Left (NoSingleState target)

{- | The rounds after a move from one node to another. A loop's own back edge
starts its next round, within its budget; one entered from outside, or
restarted by an enclosing loop's next round, starts at round one; one left
is closed.
-}
enter :: OpenGraph -> (LoopId -> Natural) -> Maybe LoopId -> Node -> Node -> Map LoopId (NonEmpty Round) -> Either Refusal (Map LoopId (NonEmpty Round))
enter g fuel back from to current = Map.traverseMaybeWithKey around g.loops
  where
    inside loop = \case
        At place -> Set.member place loop.body
        Out -> False
        Exit -> False
    restarts loop = case back of
        Just outer -> maybe False (\outerAt -> loop.body `Set.isProperSubsetOf` outerAt.body) (Map.lookup outer g.loops)
        Nothing -> False
    around loopId loop = case (inside loop to, Map.lookup loopId current) of
        (False, _) -> Right Nothing
        (True, Just done) | back == Just loopId -> Just <$> nextRound loopId (fuel loopId) done
        (True, Just done) | inside loop from && not (restarts loop) -> Right (Just done)
        (True, _) -> Right (Just firstRound)

nextRound :: LoopId -> Natural -> NonEmpty Round -> Either Refusal (NonEmpty Round)
nextRound loopId fuel done
    | fromIntegral (length done) < budget fuel (NonEmpty.last done) = Right (done <> (Round Set.empty :| []))
    | otherwise = Left (OutOfFuel loopId fuel)

{- | The rounds a loop may run: its fuel, and one more when the last round
holds a Not met (#351), never more, so a Not met that never clears still ends.
-}
budget :: Natural -> Round -> Natural
budget fuel (Round latest)
    | any unmet latest = fuel + 1
    | otherwise = fuel
  where
    unmet = \case
        Unmet _ -> True
        Row _ -> False
        Failing _ -> False

firstRound :: NonEmpty Round
firstRound = Round Set.empty :| []

noteProblems :: Set Problem -> NonEmpty Round -> NonEmpty Round
noteProblems new rounds = case NonEmpty.reverse rounds of
    Round latest :| before -> NonEmpty.reverse (Round (latest <> new) :| before)

-- | The rows a pick leaves to fix and the requirements it judged not met.
reviewProblems :: Outcome (s :: ReviewStep) l -> Set Problem
reviewProblems = \case
    PickFinal picks -> picked picks
    PickLoop picks -> picked picks
    ReviewClean _ -> Set.empty
    ReviewRows _ -> Set.empty
    FixDone _ -> Set.empty
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
    SimplifyPrDone _ -> (Set.empty, Nothing)
    SimplifyPrSkipped _ -> (Set.empty, Nothing)
    AwaitCiGreen _ -> (Set.empty, Nothing)
    FixPrDone _ -> (Set.empty, Nothing)

-- | Balanced and Normal until recorded, as a brief with no @Quality@ or @Size@ line reads.
mode :: RunState -> Mode
mode state = Mode (fromMaybe Balanced state.quality) (fromMaybe Normal state.size)

-- | A loop making no progress: these problems were in both of its last two rounds.
data Stuck = Stuck {loop :: LoopId, same :: Set Problem}
    deriving stock (Eq, Show)

{- | Only the last two rounds, and only in a row, as #351 decided. It misses
rows alternating A, B, A, B on purpose: no two rounds in a row share a row, and
the loop's fuel ends it.
-}
stuck :: RunState -> [Stuck]
stuck state =
    [ Stuck loopId same
    | (loopId, rounds) <- Map.toList state.rounds
    , Round current : Round previous : _ <- [reverse (NonEmpty.toList rounds)]
    , let same = Set.intersection previous current
    , not (Set.null same)
    ]
