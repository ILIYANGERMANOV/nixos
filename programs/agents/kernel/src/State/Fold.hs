{- | What a run knows is a fold over its log (#351 section 7). A step event
moves the run along one edge of the flow's graph, found by "State.Path", so a
log the fold accepts is a path of @Run(F)@ (law Trace soundness). Every loop
has fuel and the stuck guard short-circuits it (law Bounded).
-}
module State.Fold (
    RunState (..),
    Round (..),
    Problem (..),
    Refusal (..),
    Append (..),
    replay,
    fold,
    append,
    mode,
    Stuck (..),
    stuck,
) where

import Control.Monad (foldM)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Numeric.Natural (Natural)
import State.Cap (EventName)
import State.Event (Check, Envelope (..), Event (..), EventId, Judgement (..), Label, Note, Outcome (..), Picks (..), Requirement, RunId, Start, Stop, Verdict (..), eventId, outcomeEvent)
import State.Flow (LoopId, OptId)
import State.Graph (Arrow (..), Edge (..), LoopAt (..), Node (..), OpenGraph (..), Place (..))
import State.Mode (Cfg (..), Mode (..), Quality (..), Size (..), SkipWhen (..), cfg)
import State.Path (step)

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
    }
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
      NoSingleState Text
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
begin g envelope = case envelope.event of
    Started start ->
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
                }
    QualitySet _ -> Left NotStarted
    SizeSet _ -> Left NotStarted
    Grew _ -> Left NotStarted
    Took _ -> Left NotStarted
    Stopped _ -> Left NotStarted
    Overridden _ _ -> Left NotStarted
    Refused _ -> Left NotStarted

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
    Stopped stop -> going (Right state {stopped = Just stop})
    Overridden name _ -> going (overridden g state name)
  where
    going next = case state.stopped of
        Just stop -> Left (AfterStop stop)
        Nothing -> (\moved -> moved {refused = Nothing}) <$> next

-- | Moves along the outcome's edge, after the outcome's problems join the rounds it ends.
took :: OpenGraph -> RunState -> Outcome -> Either Refusal RunState
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
    let noted = fmap (noteProblems (problems outcome)) state.rounds
    rounds <- enter g (mode state) edge.back state.at edge.to noted
    Right state {at = edge.to, rounds}

overridden :: OpenGraph -> RunState -> Text -> Either Refusal RunState
overridden g state name = case Set.toList (Set.filter (\place -> place.name == name) places) of
    [place] -> do
        rounds <- enter g (mode state) Nothing state.at (At place) state.rounds
        Right state {at = At place, rounds}
    _ -> Left (NoSingleState name)
  where
    places = Set.fromList (map fst (Map.keys g.edges))

{- | The rounds after a move from one node to another. A loop's own back edge
starts its next round, within its budget; one entered from outside, or
restarted by an enclosing loop's next round, starts at round one; one left
is closed.
-}
enter :: OpenGraph -> Mode -> Maybe LoopId -> Node -> Node -> Map LoopId (NonEmpty Round) -> Either Refusal (Map LoopId (NonEmpty Round))
enter g m back from to current = Map.traverseMaybeWithKey around g.loops
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
        (True, Just done) | back == Just loopId -> Just <$> nextRound loopId ((cfg m).fuel loopId) done
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

problems :: Outcome -> Set Problem
problems = \case
    PickFinal picks -> picked picks
    PickLoop picks -> picked picks
    AwaitCiRed _ failing -> Set.fromList (map Failing (NonEmpty.toList failing))
    ResearchDone _ -> Set.empty
    ResearchSkipped -> Set.empty
    InterviewEnough -> Set.empty
    InterviewMore -> Set.empty
    PlanDone _ -> Set.empty
    SimplifyPlanDone -> Set.empty
    SimplifyPlanSkipped -> Set.empty
    AlternativeDone -> Set.empty
    AlternativeSkipped -> Set.empty
    ConfirmConfirmed -> Set.empty
    ConfirmAdjusted -> Set.empty
    DraftDone _ -> Set.empty
    ImplementDone _ -> Set.empty
    RefactorDone _ -> Set.empty
    RefactorSkipped _ -> Set.empty
    ReviewClean _ -> Set.empty
    ReviewRows _ -> Set.empty
    FixDone _ -> Set.empty
    DescribeDone _ -> Set.empty
    SimplifyPrDone _ -> Set.empty
    SimplifyPrSkipped _ -> Set.empty
    AwaitCiGreen _ -> Set.empty
    FixPrDone _ -> Set.empty
    ReadyDone _ -> Set.empty
    ReadySkipped _ -> Set.empty
  where
    picked picks =
        Set.fromList (map Row picks.rows)
            <> Set.fromList [Unmet verdict.requirement | verdict <- picks.verdicts, verdict.judgement == NotMet]

-- | Balanced and Normal until recorded, as a brief with no @Quality@ or @Size@ line reads.
mode :: RunState -> Mode
mode state = Mode (fromMaybe Balanced state.quality) (fromMaybe Normal state.size)

-- | A loop making no progress: these problems were in both of its last two rounds.
data Stuck = Stuck {loop :: LoopId, same :: Set Problem}
    deriving stock (Eq, Show)

{- | Only the last two rounds, and only in a row, as #351 decided. #351 noted
that the Python guard (@core.py:557@) misses rows alternating A, B, A, B; this
rule misses them too, on purpose: no two rounds in a row share a row, and the
loop's fuel ends it.
-}
stuck :: RunState -> [Stuck]
stuck state =
    [ Stuck loopId same
    | (loopId, rounds) <- Map.toList state.rounds
    , Round current : Round previous : _ <- [reverse (NonEmpty.toList rounds)]
    , let same = Set.intersection previous current
    , not (Set.null same)
    ]
