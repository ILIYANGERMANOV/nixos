-- | Runs of the engineer flow, for the specs that read a run's state.
module State.Run.RunGen (
    g,
    tenXGraph,
    architectGraph,
    chiefGraph,
    ticketUrl,
    ticketWritten,
    userConfirms,
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
    refined,
    refinedTranscript,
    researchedIn,
    spawnedIn,
    enoughIn,
    within,
    skipOf,
    runOf,
    pickOf,
    runAt,
    runUnder,
    loadSteps,
    genAccepted,
    genAcceptedOn,
    outcomeOf,
) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Category.Flow (
    Flow (..),
    Name (..),
    ScopePath,
    scopePath,
    unqualify,
 )
import State.Category.Fuel (Fuel (..), fuelName)
import State.Category.Graph (
    Edge (..),
    LoopAt (..),
    Node (..),
    OpenGraph (..),
    Place (..),
    graph,
    outOf,
 )
import State.Category.Graph qualified as Graph
import State.Category.Path (unrecorded)
import State.Category.Step (
    EventName (..),
    OutcomeName (..),
    spawnedOutcome,
    stateNameText,
 )
import State.Category.Ty (NotSum, TyOf (..))
import State.Flow.Block (review)
import State.Flow.Role.Architect (architect)
import State.Flow.Role.Chief (chief)
import State.Flow.Role.Engineer (engineer)
import State.Flow.Role.TenX (tenX)
import State.Role (drawnOutcomes)
import State.Run.Ask (Above (..), Kind (Confirm), QId (..), Question (..))
import State.Run.Codec (branchText, repoText, taskIdText, topicText, urlText)
import State.Run.Event
import State.Run.Event qualified as Event (Start (..))
import State.Run.EventGen (
    fuelSet,
    genOutcomeNamed,
    line,
    logOf,
    oneLine,
    run,
    runId,
    start,
    started,
    tasksOf,
 )
import State.Run.Fold (
    Append (..),
    Refusal,
    RunState (..),
    Worker (..),
    append,
    replay,
 )
import State.Step.Artifact (shellPathText)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome)
import State.Step.Catalog qualified as Catalog
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
securityGraph = either (error . show) id (graph (review :> Scope "security" review))

-- | The @security@ scope.
securityScope :: ScopePath
securityScope = scopePath "security"

-- | A whole flow run inline, under a scope named after it.
scopedIn :: (NotSum o) => Name -> Flow s 'Ctx 'Nothing o -> OpenGraph
scopedIn name flow = either (error . show) id (graph (Scope name flow))

tenXGraph :: OpenGraph
tenXGraph = either (error . show) id (graph tenX)

architectGraph :: OpenGraph
architectGraph = either (error . show) id (graph architect)

chiefGraph :: OpenGraph
chiefGraph = either (error . show) id (graph chief)

-- | The ticket an architect run writes its design into.
ticketUrl :: Url
ticketUrl = Url "https://github.com/o/r/issues/1"

-- | The ticket picked at the architect's discussion and written at 'ticketUrl': the run is back at the pick.
ticketWritten :: [Event]
ticketWritten =
    [Took mempty (pickOf "architect" "ticket"), stepTook (TicketWritten ticketUrl)]

{- | The user's word at a step that asks Confirm: the question asked there,
forwarded to the user and answered. @n@ numbers it, unique in its log.
-}
userConfirms :: Natural -> StateName -> [Event]
userConfirms n at =
    [ Asked (Asking question at Itself)
    , Forwarded question.qid TheUser
    , Answered question.qid (Chose "yes") TheUser
    ]
  where
    question = Question (QId run n) Confirm (oneLine (stateNameText at <> ": confirmed?"))

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
tenXAt tasks events =
    either
        (error . show)
        id
        (replay tenXGraph (logOf (Started tenXStart :| toFanOut <> events)))
  where
    tenXStart = start {Event.flow = TenXFlow}
    toFanOut =
        [ fuelSet Balanced
        , Overridden (StateName "breakdown") "the plan is agreed"
        , stepTook (BreakdownDone engineers (tasksOf tasks))
        ]

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
childOf child task = Child (runId child) (Tasked (TaskId task)) (Text.unpack child)

sha :: Sha
sha = Sha "abc123"

commit :: Commit
commit = Commit sha Set.empty

-- | An engineer run from its gather to its PR ready: one researcher, the plan confirmed, a clean review.
happyPath :: [Event]
happyPath =
    researchedIn "gather"
        <> enoughIn "gather"
        <> map
            (Took mempty)
            ( [outcome (PlanDone "plan.md")]
                <> refined
                <> [outcome ConfirmConfirmed]
                <> [ outcome (DraftDone (DraftPr (Url "u") (Branch "main") (Branch "b")))
                   , outcome (ImplementDone commit)
                   , runOf "refactor"
                   , outcome (RefactorDone sha)
                   , outcome (ReviewClean sha)
                   ]
                <> [ outcome (DescribeDone sha)
                   , outcome (VisualDone sha)
                   , outcome (SimplifyPrDone sha)
                   , outcome (AwaitCiGreen sha)
                   , outcome (ReadyDone (Url "u"))
                   ]
            )

-- | A plan's refine passes run, then its presentation: from @plan@'s done to @confirm@.
refined :: [AnyOutcome]
refined =
    [ runOf "refine"
    , outcome SimplifyPlanDone
    , outcome StandardsPlanDone
    , outcome AlignPlanDone
    , outcome PresentDone
    ]

-- | 'refined' as @state next@ walks it, one transition line per event.
refinedTranscript :: [Text]
refinedTranscript =
    [ "artifact -> plan"
    , "plan.done -> skip_refine"
    , "skip_refine.run -> simplify_plan"
    , "simplify_plan.done -> standards_plan"
    , "standards_plan.done -> align_plan"
    , "align_plan.done -> present"
    , "present.done -> confirm"
    ]

-- | A researcher spawned from this choice's pick, then its hand-back: the run is back at the pick.
researchedIn :: Text -> [Event]
researchedIn choice = spawnedIn choice <> [stepTook ResearchHandedBack]

-- | A researcher spawned from this choice's pick, in the background: the run is back at the pick.
spawnedIn :: Text -> [Event]
spawnedIn choice =
    [ Took mempty (pickOf choice "research")
    , tookIn (scopePath (Name choice)) ResearchSpawned
    ]

-- | This choice's enough with no researcher open: past its await, the notes merged.
enoughIn :: Text -> [Event]
enoughIn choice =
    [ Took mempty (pickOf choice "enough")
    , tookIn (scopePath (Name choice)) NotesDone
    ]

-- | These events as a flow run inline under this scope records them.
within :: Name -> [Event] -> [Event]
within scope = map $ \case
    Took bare o -> Took (scopePath scope <> bare) o
    other -> other

-- | The outcome that skips the flows' optional block of this name.
skipOf :: Text -> AnyOutcome
skipOf = skipStep "skip"

-- | The outcome that runs the flows' optional block of this name.
runOf :: Text -> AnyOutcome
runOf = skipStep "run"

skipStep :: Text -> Text -> AnyOutcome
skipStep way block = drawn ("skip_" <> block) way

-- | The outcome of the flows' pick of this name that takes this label.
pickOf :: Text -> Text -> AnyOutcome
pickOf = drawn

-- | The flows' drawn outcome of this event: a skip's or a pick's.
drawn :: Text -> Text -> AnyOutcome
drawn step way =
    fromMaybe
        (error ("no drawn " <> Text.unpack step <> "." <> Text.unpack way))
        ( find
            ((== EventName (StateName step) (OutcomeName way)) . Catalog.outcomeEvent)
            drawnOutcomes
        )

{- | Up to 300 tries at an event on an edge out of where the run is, or a
researcher's hand-back while one is open, any Fuel at a Fuel step, keeping
those the fold accepts. An await's edges take no event: the run goes on by
itself once its group handed back. Edges into a loop that leave none
are likelier, so loops run out of rounds: a review with rows enters the fix
loop rather than exiting clean.
-}
genAccepted :: Gen [Event]
genAccepted = genAcceptedOn [] g

{- | 'genAccepted' on any graph: an edge inside a scope is taken in its
place's scope. The outcomes given are the flow's own picks and skips, which
no role's flow draws (a generated term's), found before the drawn ones.
-}
genAcceptedOn :: [AnyOutcome] -> OpenGraph -> Gen [Event]
genAcceptedOn own on = do
    steps <- Gen.int (Range.linear 0 300)
    first <- either (fail . show) pure (replay on (logOf (started :| [])))
    go steps first 1
  where
    go :: Int -> RunState -> Natural -> Gen [Event]
    go 0 _ _ = pure []
    go k state n = case state.at of
        -- At a fan-out's await, only the 10x's own events, which this draws none of, move the run.
        At place -> case handBacks place state
            <> [ (if stays place edge then 5 else 1, tookBy place name)
               | isNothing (unrecorded on place)
               , (name, edge) <- outOf place on.edges
               ] of
            [] -> pure []
            choices -> do
                took <- Gen.frequency choices
                case appended state n took of
                    Right (next, m) -> (took <>) <$> bound next m (bindOf took n)
                    Left _ -> go (k - 1) state n
              where
                -- A researcher's spawn is bound to its agent next, as the bind hook logs it.
                bound next m = \case
                    Just bind
                        | Right (Appended after) <- append on next (line m bind) ->
                            (bind :) <$> go (k - 1) after (m + 1)
                    _ -> go (k - 1) next m
        Out -> pure []
        Graph.Exit -> pure []
    -- Each line accepted, in order: the run after them and the next seq; none when one is refused or logged already.
    appended ::
        RunState -> Natural -> [Event] -> Either (Maybe Refusal) (RunState, Natural)
    appended state n = \case
        [] -> Right (state, n)
        event : rest -> case append on state (line n event) of
            Right (Appended next) -> appended next (n + 1) rest
            Right AlreadyLogged -> Left Nothing
            Left refusal -> Left (Just refusal)
    -- The edge is named in the place's scope; the outcome is its step's own.
    tookBy place name =
        pure . Took place.scope
            <$> outcomeIn
                own
                (EventName (StateName (snd (unqualify (stateNameText name.step)))) name.outcome)
    {- A researcher in the background may return wherever the run is; at an
    await, only it moves the run on. Its hand-back is taken anywhere, before
    its bind too, and closes nothing.
    -}
    handBacks place state =
        [ (3, pure [WorkerReturned researcher Nothing])
        | any ((== researcher) . (.role)) state.workers
        ]
            <> [(1, pure [Took place.scope (outcome ResearchHandedBack)])]
    bindOf took n = case took of
        [Took scope spawn]
            | (tookEvent scope spawn).outcome == spawnedOutcome ->
                Just (WorkerSpawned researcher (AgentId ("r" <> Text.pack (show n))))
        _ -> Nothing
    researcher = AgentRole "researcher"
    stays place edge = case edge.to of
        At to ->
            all
                (\loop -> not (Set.member place loop.body) || Set.member to loop.body)
                (Map.elems on.loops)
                && any (Set.member to . (.body)) (Map.elems on.loops)
        Out -> False
        Graph.Exit -> False

outcomeOf :: EventName -> Gen AnyOutcome
outcomeOf = outcomeIn []

-- | 'outcomeOf', one of these outcomes first.
outcomeIn :: [AnyOutcome] -> EventName -> Gen AnyOutcome
outcomeIn own name =
    maybe
        (fromMaybe Gen.discard (genOutcomeNamed name))
        pure
        (find ((== name) . Catalog.outcomeEvent) own)

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
