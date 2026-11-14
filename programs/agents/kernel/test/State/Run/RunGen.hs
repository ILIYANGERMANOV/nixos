-- | Runs of the engineer flow, for the specs that read a run's state.
module State.Run.RunGen (
    g,
    tenXGraph,
    tenXAt,
    plainTask,
    breakdownJson,
    childOf,
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

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Category.Graph (Edge (..), LoopAt (..), Node (..), OpenGraph (..), graph)
import State.Category.Mode (Quality (..), Size (..), qualityName, sizeName)
import State.Category.Step (EventName)
import State.Flow.Engineer (engineer)
import State.Flow.TenX (tenX)
import State.Run.Codec (branchText, taskIdText, topicText)
import State.Run.Event
import State.Run.EventGen (genOutcomeNamed, line, logOf, runId, start, started, tasksOf)
import State.Run.Fold (Append (..), RunState (..), append, replay)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome)
import State.Step.Fan (Outcome (..))
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..))
import State.Table (Steps, parseSteps)
import System.Environment (getEnv)

g :: OpenGraph
g = either (error . show) id (graph engineer)

tenXGraph :: OpenGraph
tenXGraph = either (error . show) id (graph tenX)

{- | A 10x run, by the user, Balanced Normal, at its fan-out with these
tasks, then these events.
-}
tenXAt :: NonEmpty Task -> [Event] -> RunState
tenXAt tasks events = either (error . show) id (replay tenXGraph (logOf (Started tenXStart :| toFanOut <> events)))
  where
    tenXStart = start {flow = TenXFlow}
    toFanOut = [QualitySet Balanced, SizeSet Normal, Overridden (StateName "breakdown") "the plan is agreed", stepTook (BreakdownDone (tasksOf tasks))]

-- | A task on its own branch off main, Balanced Normal, light, after these tasks.
plainTask :: Text -> [Text] -> Task
plainTask name deps = Task (TaskId name) (map TaskId deps) (Branch "main") (Branch name) Balanced Normal False False Set.empty

-- | The breakdown file the 10x writes for these tasks, in this order.
breakdownJson :: [Task] -> Text
breakdownJson = decodeUtf8 . LBS.toStrict . Aeson.encode . map taskJson
  where
    taskJson task =
        object
            [ "id" .= taskIdText task.id
            , "deps" .= map taskIdText task.deps
            , "base" .= branchText task.base
            , "branch" .= branchText task.branch
            , "quality" .= qualityName task.quality
            , "size" .= sizeName task.size
            , "qa" .= task.qa
            , "heavy" .= task.heavy
            , "security" .= map topicText (Set.toList task.security)
            ]

-- | The child run of this id, for this task.
childOf :: Text -> Text -> Child
childOf child task = Child (runId child) (TaskId task) (Text.unpack child <> "/events.jsonl") (Text.unpack child)

sha :: Sha
sha = Sha "abc123"

commit :: Commit
commit = Commit sha Set.empty

happyPath :: [AnyOutcome]
happyPath =
    [outcome (ResearchDone 3), outcome InterviewEnough, outcome (PlanDone "plan.md"), outcome SimplifyPlanDone, outcome ConfirmConfirmed]
        <> [outcome (DraftDone (DraftPr (Url "u") (Branch "main") (Branch "b"))), outcome (ImplementDone commit), outcome (RefactorDone sha), outcome (ReviewClean sha)]
        <> [outcome (DescribeDone sha), outcome (SimplifyPrDone sha), outcome (AwaitCiGreen sha), outcome (ReadyDone (Url "u"))]

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
            took <- outcomeOf name
            case append g state (line n (Took took)) of
                Right (Appended next) -> (Took took :) <$> go (k - 1) next (n + 1)
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

outcomeOf :: EventName -> Gen AnyOutcome
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
