-- | Runs of the engineer flow, for the specs that read a run's state.
module State.Run.RunGen (
    g,
    tenXGraph,
    architectGraph,
    chiefGraph,
    ticketUrl,
    ticketOpened,
    designWritten,
    securityGraph,
    securityScope,
    scopedIn,
    flowGraph,
    tenXAt,
    plainTask,
    roundTask,
    breakdownJson,
    taskFileJson,
    childOf,
    sha,
    commit,
    happyPath,
    runAt,
    runUnder,
    loadSteps,
    genAccepted,
    genAcceptedOn,
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
import State.Category.Flow (Flow (..), Name, ScopePath, scopePath, unqualify)
import State.Category.Fuel (Fuel (..), fuelName)
import State.Category.Graph (Edge (..), LoopAt (..), Node (..), OpenGraph (..), Place (..), graph)
import State.Category.Graph qualified as Graph
import State.Category.Step (EventName (..), stateNameText)
import State.Category.Ty (NotSum, TyOf (..))
import State.Flow.Architect (architect)
import State.Flow.Chief (chief)
import State.Flow.Engineer (engineer)
import State.Flow.Library (reviewed)
import State.Flow.TenX (tenX)
import State.Run.Codec (branchText, repoText, taskIdText, topicText, urlText)
import State.Run.Event
import State.Run.Event qualified as Event (Start (..))
import State.Run.EventGen (genOutcomeNamed, line, logOf, runId, start, started, tasksOf)
import State.Run.Fold (Append (..), RunState (..), append, replay)
import State.Step.Artifact (shellPathText)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome)
import State.Step.Choice (Outcome (..), discussing, exploring, gathering)
import State.Step.Fan (Outcome (..), engineers)
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..))
import State.Step.Ticket (Outcome (..))
import State.Table (Steps, parseSteps)
import System.Environment (getEnv)

g :: OpenGraph
g = either (error . show) id (graph engineer)

-- | A review, then the same review again inside the @security@ scope.
securityGraph :: OpenGraph
securityGraph = either (error . show) id (graph (reviewed :> Scope "security" reviewed))

-- | The @security@ scope.
securityScope :: ScopePath
securityScope = scopePath "security"

-- | A whole flow run inline, under a scope named after it.
scopedIn :: (NotSum o) => Name -> Flow 'Ctx 'Nothing o -> OpenGraph
scopedIn name flow = either (error . show) id (graph (Scope name flow))

tenXGraph :: OpenGraph
tenXGraph = either (error . show) id (graph tenX)

architectGraph :: OpenGraph
architectGraph = either (error . show) id (graph architect)

chiefGraph :: OpenGraph
chiefGraph = either (error . show) id (graph chief)

-- | The ticket an architect run opens.
ticketUrl :: Url
ticketUrl = Url "https://github.com/o/r/issues/1"

-- | An architect run up to its ticket: researched, explored enough, the ticket opened.
ticketOpened :: [Event]
ticketOpened = [stepTook ResearchSpawned, stepTook ResearchHandedBack, stepTook (Enough exploring), stepTook (OpenTicketDone ticketUrl)]

-- | A design round up to the user's verdict: discussed, written into the ticket.
designWritten :: [Event]
designWritten = [stepTook (Enough discussing), stepTook UpdateTicketDone]

-- | The graph a run of this flow walks.
flowGraph :: FlowName -> OpenGraph
flowGraph = \case
    EngineerFlow -> g
    TenXFlow -> tenXGraph
    ArchitectFlow -> architectGraph
    ChiefFlow -> chiefGraph

{- | A 10x run, by the user, at its fan-out with these
tasks, then these events.
-}
tenXAt :: NonEmpty Task -> [Event] -> RunState
tenXAt tasks events = either (error . show) id (replay tenXGraph (logOf (Started tenXStart :| toFanOut <> events)))
  where
    tenXStart = start {Event.flow = TenXFlow}
    toFanOut = [Overridden (StateName "breakdown") "the plan is agreed", stepTook (BreakdownDone engineers (tasksOf tasks))]

-- | A task on its own branch off main, Balanced, light, after these tasks.
plainTask :: Text -> [Text] -> Task
plainTask name deps =
    Task
        { id = TaskId name
        , deps = map TaskId deps
        , base = Branch "main"
        , branch = Branch name
        , fuel = Balanced
        , qa = False
        , heavy = False
        , security = Set.empty
        , shape = OwnPr
        , plan = ChildConfirms
        , repo = Nothing
        , worktree = Nothing
        , flow = EngineerFlow
        }

-- | A round on the existing PR @pr@: a plain task otherwise.
roundTask :: Text -> Text -> Task
roundTask name pr = (plainTask name []) {shape = RoundOn (Url pr)}

-- | The breakdown file the 10x writes for these tasks, in this order.
breakdownJson :: [Task] -> Text
breakdownJson = decodeUtf8 . LBS.toStrict . Aeson.encode . map taskJson

-- | The file the 10x writes for @task add@.
taskFileJson :: Task -> Text
taskFileJson = decodeUtf8 . LBS.toStrict . Aeson.encode . taskJson

taskJson :: Task -> Aeson.Value
taskJson task =
    object $
        [ "id" .= taskIdText task.id
        , "deps" .= map taskIdText task.deps
        , "base" .= branchText task.base
        , "branch" .= branchText task.branch
        , "fuel" .= fuelName task.fuel
        , "qa" .= task.qa
        , "heavy" .= task.heavy
        , "security" .= map topicText (Set.toList task.security)
        ]
            <> case task.shape of
                OwnPr -> []
                RoundOn url -> ["pr" .= urlText url]
            <> case task.plan of
                ChildConfirms -> []
                ParentDecided -> ["planDecided" .= True]
            <> maybe [] (\repo -> ["repo" .= repoText repo]) task.repo
            <> maybe [] (\path -> ["worktree" .= shellPathText path]) task.worktree
            <> case task.flow of
                EngineerFlow -> []
                TenXFlow -> ["flow" .= ("10x" :: Text)]
                ArchitectFlow -> ["flow" .= ("architect" :: Text)]
                ChiefFlow -> ["flow" .= ("chief" :: Text)]

-- | The child run of this id, for this task.
childOf :: Text -> Text -> Child
childOf child task = Child (runId child) (TaskId task) (Text.unpack child <> "/events.jsonl") (Text.unpack child)

sha :: Sha
sha = Sha "abc123"

commit :: Commit
commit = Commit sha Set.empty

happyPath :: [AnyOutcome]
happyPath =
    [outcome ResearchSpawned, outcome ResearchHandedBack, outcome (Enough gathering), outcome (PlanDone "plan.md"), outcome SimplifyPlanDone, outcome ConfirmConfirmed]
        <> [outcome (DraftDone (DraftPr (Url "u") (Branch "main") (Branch "b"))), outcome (ImplementDone commit), outcome (RefactorDone sha), outcome (ReviewClean sha)]
        <> [outcome (DescribeDone sha), outcome (SimplifyPrDone sha), outcome (AwaitCiGreen sha), outcome (ReadyDone (Url "u"))]

{- | Any Fuel, then up to 300 tries at an event on an edge out of where the
run is, keeping those the fold accepts. Edges into a loop that leave none
are likelier, so loops run out of rounds: a review with rows enters the fix
loop rather than exiting clean.
-}
genAccepted :: Gen [Event]
genAccepted = genAcceptedOn g

-- | 'genAccepted' on any graph: an edge inside a scope is taken in its place's scope.
genAcceptedOn :: OpenGraph -> Gen [Event]
genAcceptedOn on = do
    knobs <- genKnobs
    steps <- Gen.int (Range.linear 0 300)
    first <- either (fail . show) pure (replay on (logOf (started :| knobs)))
    (knobs <>) <$> go steps first (fromIntegral (length knobs) + 1)
  where
    go :: Int -> RunState -> Natural -> Gen [Event]
    go 0 _ _ = pure []
    go k state n = case state.at of
        At place -> do
            name <- Gen.frequency [(if stays place edge then 5 else 1, pure name) | ((from, name), edge) <- Map.toList on.edges, from == place]
            -- The edge is named in the place's scope; the outcome is its step's own, a choice's action's at a choice.
            took <- Took place.scope <$> outcomeOf (EventName (StateName (snd (unqualify (stateNameText name.step)))) name.outcome)
            case append on state (line n took) of
                Right (Appended next) -> (took :) <$> go (k - 1) next (n + 1)
                Right AlreadyLogged -> go (k - 1) state n
                Left _ -> go (k - 1) state n
        Out -> pure []
        Graph.Exit -> pure []
    stays place edge = case edge.to of
        At to ->
            all (\loop -> not (Set.member place loop.body) || Set.member to loop.body) (Map.elems on.loops)
                && any (Set.member to . (.body)) (Map.elems on.loops)
        Out -> False
        Graph.Exit -> False

genKnobs :: Gen [Event]
genKnobs = (\fuel -> [FuelSet fuel]) <$> Gen.enumBounded

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
