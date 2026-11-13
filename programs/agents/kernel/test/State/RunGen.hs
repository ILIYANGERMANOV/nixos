-- | Runs of the engineer flow, for the specs that read a run's state.
module State.RunGen (
    g,
    tenXGraph,
    sha,
    commit,
    happyPath,
    runAt,
    runUnder,
    loadSteps,
    genAccepted,
    genKnobs,
    outcomeOf,
) where

import Data.ByteString.Lazy qualified as LBS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Cap (EventName)
import State.Event
import State.EventGen (genOutcomeNamed, line, logOf, start, started)
import State.Flows.Engineer (engineer)
import State.Flows.TenX (tenX)
import State.Fold (Append (..), RunState (..), append, replay)
import State.Graph (Edge (..), LoopAt (..), Node (..), OpenGraph (..), graph)
import State.Steps (Steps, parseSteps)
import System.Environment (getEnv)

g :: OpenGraph
g = either (error . show) id (graph engineer)

tenXGraph :: OpenGraph
tenXGraph = either (error . show) id (graph tenX)

sha :: Sha
sha = Sha "abc123"

commit :: Commit
commit = Commit sha Set.empty

happyPath :: [Outcome]
happyPath =
    [ResearchDone 3, InterviewEnough, PlanDone "plan.md", SimplifyPlanDone, AlternativeDone, ConfirmConfirmed]
        <> [DraftDone (DraftPr (Url "u") (Branch "main") (Branch "b")), ImplementDone commit, RefactorDone sha, ReviewClean sha]
        <> [DescribeDone sha, SimplifyPrDone sha, AwaitCiGreen sha, ReadyDone (Url "u")]

{- | Any mode, then up to 300 tries at an event on an edge out of where the
run is, keeping those the fold accepts. Edges that stay inside every loop are
likelier, so loops run out of fuel.
-}
genAccepted :: Gen [Event]
genAccepted = do
    knobs <- genKnobs
    steps <- Gen.int (Range.linear 0 300)
    first <- either (fail . show) pure (replay g (logOf (started :| knobs)))
    (knobs <>) <$> go steps first (fromIntegral (length knobs) + 1)
  where
    go :: Int -> RunState -> Natural -> Gen [Event]
    go 0 _ _ = pure []
    go k state n = case state.at of
        At place -> do
            name <- Gen.frequency [(if stays place edge then 5 else 1, pure name) | ((from, name), edge) <- Map.toList g.edges, from == place]
            outcome <- outcomeOf name
            case append g state (line n (Took outcome)) of
                Right (Appended next) -> (Took outcome :) <$> go (k - 1) next (n + 1)
                Right AlreadyLogged -> go (k - 1) state n
                Left _ -> go (k - 1) state n
        Out -> pure []
        Exit -> pure []
    stays place edge = case edge.to of
        At to -> all (\loop -> not (Set.member place loop.body) || Set.member to loop.body) (Map.elems g.loops)
        Out -> False
        Exit -> False

genKnobs :: Gen [Event]
genKnobs = (\quality size -> [QualitySet quality, SizeSet size]) <$> Gen.enumBounded <*> Gen.enumBounded

outcomeOf :: EventName -> Gen Outcome
outcomeOf name = fromMaybe Gen.discard (genOutcomeNamed name)

-- | The run after these events, from 'started'; the events must be a log the fold accepts.
runAt :: [Event] -> RunState
runAt = runUnder start

-- | 'runAt' for a run started so.
runUnder :: Start -> [Event] -> RunState
runUnder from events = either (error . show) id (replay g (logOf (Started from :| events)))

-- | The flows' step table the build exports as STATE_STEPS (kernel/default.nix).
loadSteps :: IO Steps
loadSteps = do
    table <- LBS.readFile =<< getEnv "STATE_STEPS"
    either (fail . Text.unpack . Text.unlines) pure (parseSteps table)
