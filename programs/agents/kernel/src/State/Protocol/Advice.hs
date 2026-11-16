{- | What a run does next, decided from its state alone (#360's @state next@).
'advise' never reads who started the run or what its interface can do (law
Principal-blind); 'deliver' alone turns the advice into the line that
principal and interface need.
-}
module State.Protocol.Advice (
    Facts (..),
    changedLinesOf,
    PullRequest (..),
    Readiness (..),
    PrView (..),
    prViewFields,
    pullRequestOf,
    Advice (..),
    Action (..),
    explained,
    due,
    skippable,
    advise,
    deliver,
    deliverPrompt,
    ownAsk,
    factLines,
) where

import Control.Applicative ((<|>))
import Control.Monad (join, mfilter)
import Data.Aeson (eitherDecodeStrictText, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Foldable (asum, toList)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import Numeric.Natural (Natural)
import State.Category.Flow (FanEvent (Leaves), enoughOutcome, fanEvent, nameText, namedState, qualify)
import State.Category.Fuel (SkipWhen (..), atFuel, fuelLabel, fuelName)
import State.Category.Graph (Arrow (..), Cap (..), Edge (..), Metered (..), Node (..), OpenGraph (..), Place (..), placeName, shownOrder)
import State.Category.Meter (AtCap (Extend), someMeterName)
import State.Category.Step (EventName (..), Outcomes (..), Sing, SomeStep (..), Special (AsksConfirm, AwaitsMerge, Ordinary), StepSet (..), builtEvent, eventText, handedBackOutcome, outcomeNames, spawnedOutcome, stateNameText)
import State.Category.Step qualified as Step
import State.Protocol.Handback (stopLine)
import State.Protocol.Record (Option (..), capRecords, commandOption, extendOption, goes, recordCommand, recordOption)
import State.Role (FlowName (..), RoleDef (..))
import State.Role qualified as Role
import State.Run.Ask (Above (..), Delivery (..), Kind, OneLine, QId, Question (..), kindName, needsDecision, oneLineText, qidText)
import State.Run.Ask qualified as Ask
import State.Run.Codec (reasonText, taskIdText, taskStateArgs, taskStateName, urlText)
import State.Run.Event (AgentRole (..), Asker (Itself), Asking (..), Branch (..), Child (..), DraftPr (..), Event (Asked, Forwarded), Requirement (..), RunId, Said (..), Start (..), Stop (..), Task (..), TaskId, TaskState (..), Url (..), roleText, runIdText)
import State.Run.Event qualified as Event
import State.Run.Fan (ChildRun (..), Fan (..))
import State.Run.Fan qualified as Fan
import State.Run.Fold (Budget (..), Pending (..), Problem (..), RunState (..), ScopedFan (..), Spent (..), Stuck (..), Waits (..), askedAt, askingChildren, budgets, currentFan, fanIn, flowRole, fuelOf, nextQId, onRound, stuck, usedUp)
import State.Show (firstLine, tshow)
import State.Step.Build (Outcome (..), Sing (Draft))
import State.Step.Catalog (AnyOutcome, AnyStep (..), shownEdges, stepNamed)
import State.Step.Catalog qualified as Catalog
import State.Step.Choice (choiceNamed)
import State.Step.Fan (Outcome (..), fanNamed)
import State.Step.Plan (Outcome (..))
import State.Step.Ship (Outcome (..), Sing (Ready))
import State.Table (Row (notifies, runner, task), Runner (..), Steps, row)

{- | What GitHub, git and the children's logs say, read by the shell before
it advises. @ended@ is the children whose own log shows their run over.
-}
data Facts = Facts {changedLines :: Maybe Natural, pr :: Maybe PullRequest, ended :: [RunId]}
    deriving stock (Eq, Show)

{- | @git diff --numstat@'s added plus deleted lines, as the Quality table
counts them: generated lockfiles and binary files add none.
-}
changedLinesOf :: Text -> Natural
changedLinesOf = sum . map counted . Text.lines
  where
    counted line = case Text.splitOn "\t" line of
        [added, deleted, path] | not (lockfile path) -> number added + number deleted
        _ -> 0
    number raw = case decimal raw of
        Right (n, "") -> n
        -- A binary file's row reads @-@.
        _ -> 0
    lockfile path = case reverse (Text.splitOn "/" path) of
        name : _ -> name `elem` ["flake.lock", "package-lock.json", "pnpm-lock.yaml"] || ".lock" `Text.isSuffixOf` name
        [] -> False

data PullRequest = PullRequest {draft :: DraftPr, readiness :: Readiness}
    deriving stock (Eq, Show)

-- | Where the PR stands on GitHub: open as a draft or ready for review, or over.
data Readiness = IsDraft | IsReady | IsMerged | IsClosed
    deriving stock (Eq, Show)

{- | What @gh pr view --json@ 'prViewFields' did: timed out after so many
seconds, failed with its stderr, or printed its JSON.
-}
data PrView = PrViewTimedOut Int | PrViewFailed Text | PrViewPrinted Text
    deriving stock (Eq, Show)

-- | The fields 'pullRequestOf' reads, as @gh pr view --json@ takes them.
prViewFields :: Text
prViewFields = "url,baseRefName,headRefName,isDraft,state"

-- | The branch's PR, 'Nothing' when it has none, or why GitHub was not read.
pullRequestOf :: PrView -> Either Text (Maybe PullRequest)
pullRequestOf = \case
    PrViewTimedOut seconds -> Left ("gh pr view timed out after " <> tshow seconds <> "s")
    PrViewFailed err
        | "no pull requests found" `Text.isInfixOf` err -> Right Nothing
        -- A repo with no remote, as the 10x's run directory, has no PR.
        | "no git remotes found" `Text.isInfixOf` err -> Right Nothing
        | otherwise -> Left ("gh pr view: " <> firstLine (Text.unpack err))
    PrViewPrinted out -> either (Left . ("gh pr view printed no PR: " <>) . Text.pack) (Right . Just) $ do
        value <- eitherDecodeStrictText out
        flip parseEither value $ withObject "PR" $ \o -> do
            draft <- DraftPr . Url <$> o .: "url" <*> (Branch <$> o .: "baseRefName") <*> (Branch <$> o .: "headRefName")
            isDraft <- o .: "isDraft"
            prState <- o .: "state"
            PullRequest draft <$> case (prState :: Text, isDraft) of
                ("OPEN", True) -> pure IsDraft
                ("OPEN", False) -> pure IsReady
                ("MERGED", _) -> pure IsMerged
                ("CLOSED", _) -> pure IsClosed
                _ -> fail ("unknown PR state " <> Text.unpack prState)

{- | The action; where the run is and what that means; where the step's
outcomes lead, for an action that takes none of them itself (a spawn, a
question, CI); the facts the reader weighs it by; the step's prompt text;
and whether the step notifies the user ('deliverPrompt' decides who does).
-}
data Advice = Advice {action :: Action, at :: Text, leads :: [Option], facts :: [Text], prompt :: Text, notify :: Bool}
    deriving stock (Eq, Show)

data Action
    = -- | The role to spawn, and the 10x's task it takes.
      Spawn AgentRole (Maybe TaskId)
    | -- | A question of the run's own, for @state ask --kind@.
      Ask Kind Text
    | -- | A pending question this run rules on or forwards.
      Triage Question
    | -- | A forwarded question, until its answer comes down.
      AwaitAnswer Question
    | -- | CI on this PR.
      AwaitCi Text
    | -- | A child to resume, and what with: the answer to its question, or its CI.
      Resume RunId Text
    | -- | A stopped child's stop, for @state ask --from@ before any retry.
      TriageStop RunId Stop
    | -- | A worker's hand-back line 1, for @state ask --from@ before the run goes on.
      TriageHandback AgentRole OneLine
    | -- | Tasks with an agent at work, none of them waiting on this run.
      AwaitChildren (NonEmpty TaskId)
    | -- | Tasks neither merged nor parked: the merge loop's, on approval wakes.
      AwaitMerge (NonEmpty TaskId)
    | -- | One option to take, or several to choose from.
      Run (NonEmpty Option)
    | Stopped Stop
    | Done (Maybe Url)
    deriving stock (Eq, Show)

{- | The one outcome the shell records before advising, when the facts or the
Fuel already decide it: the draft PR or its readiness seen on GitHub, or a
skip the Fuel makes, at the step's scope. The shell records it and asks
again, until 'Nothing'.
-}
due :: OpenGraph -> Facts -> RunState -> Maybe Event
due g facts state = case (state.stopped, state.at) of
    (Nothing, At place) -> Event.Took place.scope <$> listToMaybe (fromGitHub place.name <> kept place.name <> skipped place <> leaves place)
    (Nothing, Out) -> Nothing
    (Nothing, Exit) -> Nothing
    (Just _, _) -> Nothing
  where
    fromGitHub name = case facts.pr of
        Just pr
            | name == stepName Draft, open pr.readiness -> [Catalog.outcome (DraftDone pr.draft)]
            | name == stepName Ready, IsReady <- pr.readiness -> [Catalog.outcome (ReadyDone pr.draft.url)]
        _ -> []
    -- A round on an existing PR leaves it as it is, at every Fuel: the task's shape skips ready.
    kept name = [Catalog.outcome (ReadySkipped url) | name == stepName Ready, onRound state.start.principal, Just url <- [prUrl facts state]]
    -- Before the run drafts, a merged or closed PR is an old one on a reused branch name: no PR.
    open = \case
        IsDraft -> True
        IsReady -> True
        IsMerged -> False
        IsClosed -> False
    -- Every task settled: the fan-out is done, as GitHub's facts are recorded, with no one to run.
    leaves place = [Catalog.outcome (FanDone fan) | Just fan <- [fanNamed place.name], Right () <- [Fan.leave (fanIn state.fans (ScopedFan place.scope fan))]]
    -- The graph names the skip inside its scopes; its outcome is the step's own.
    skipped place =
        [ outcome
        | (event, rule) <- skipsHere g state
        , Just why <- [skipsBecause rule]
        , Just outcome <- [skipOutcome facts state why (EventName place.name event.outcome)]
        ]
    skipsBecause = \case
        Never -> Nothing
        -- The agent's call: 'skippable' says so.
        Skippable -> Nothing
        AtOrBelow most -> case facts.changedLines of
            Just changed | changed <= most -> Just (tshow changed <> " changed lines, at or below " <> tshow most)
            _ -> Nothing

{- | The outcome a skip appends. @simplify_pr@ has none here: no level skips
it, and its skip names a head these facts lack.
-}
skipOutcome :: Facts -> RunState -> Text -> EventName -> Maybe AnyOutcome
skipOutcome facts state why event =
    join . lookup event $
        map
            stated
            [ Catalog.outcome SimplifyPlanSkipped
            , Catalog.outcome (RefactorSkipped why)
            ]
            <> [(builtEvent Ready ReadySkipped, Catalog.outcome . ReadySkipped <$> prUrl facts state)]
  where
    stated skip = (Catalog.outcomeEvent skip, Just skip)

{- | The skips the run's Fuel leaves to the agent here, each with the record
that takes it: the agent skips the step of a trivial task and runs it
otherwise, so 'due' never records these.
-}
skippable :: OpenGraph -> RunState -> [Text]
skippable g state =
    [ fuelLabel (fuelOf state) <> ": skip it when the task is trivial: " <> recordCommand event
    | (event, Skippable) <- skipsHere g state
    ]

-- | Each skip arrow out of a running run's state, with when its Fuel takes it.
skipsHere :: OpenGraph -> RunState -> [(EventName, SkipWhen)]
skipsHere g state = case (state.stopped, state.at) of
    (Nothing, At place) ->
        [ (event, atFuel (fuelOf state) skips)
        | ((from, event), edge) <- Map.toList g.edges
        , from == place
        , Skip _ skips <- [edge.arrow]
        ]
    (Nothing, Out) -> []
    (Nothing, Exit) -> []
    (Just _, _) -> []

-- | The next action, from the run's state alone.
advise :: Steps -> OpenGraph -> Facts -> RunState -> Advice
advise steps g facts state = Advice action (atLine steps state) leads (factLines g facts state) prompt notify
  where
    plain next = (next, "")
    -- Where the step's outcomes lead, for an action at a step that takes none of them itself.
    leads = case (state.stopped, state.pending, state.at, action) of
        (Nothing, [], At place, Spawn _ Nothing) -> stepLeads place
        (Nothing, [], At place, Ask Ask.Confirm _) -> stepLeads place
        (Nothing, [], At place, AwaitCi _) -> stepLeads place
        _ -> []
    stepLeads place = case stepNamed place.name of
        Just (AnyStep _ (SomeStep s)) -> case (row steps s).runner of
            Agent _ _ -> [commandOption (eventText event) (goes edge) | (event, edge) <- shownEdges g place, along edge]
            Inline -> [recordOption event edge | (event, edge) <- shownEdges g place, along edge]
        Nothing -> []
    along edge = case edge.arrow of
        Along _ -> True
        Skip _ _ -> False
        Stay -> False
    notify = case (state.at, Text.null prompt) of
        (At place, False) | Just (AnyStep _ (SomeStep s)) <- stepNamed place.name -> (row steps s).notifies
        _ -> False
    (action, prompt) = case (state.stopped, state.pending, fuelAsked) of
        (Just stop, _, _) -> plain (Stopped stop)
        -- At a fan-out, a question waits beside the children's work: 'atFan' orders it.
        (Nothing, _ : _, True) | Just fan <- fanHere -> plain (atFan fan facts.ended state)
        (Nothing, oldest : _, _) -> plain $ case oldest.waits of
            ForTriage -> Triage oldest.asking.question
            ForAnswer -> AwaitAnswer oldest.asking.question
        (Nothing, [], False) -> plain (Run (one (recordOne "fuel" (map fuelName [minBound .. maxBound])) "sets the run's Fuel, once: how much it researches, reviews and spends"))
        (Nothing, [], True) -> case state.untriaged of
            (role, line) : _ -> plain (TriageHandback role line)
            [] -> going
    -- The 10x picks each task's Fuel and never asks one: it runs at the default.
    fuelAsked = case state.start.flow of
        EngineerFlow -> isJust state.fuel
        TenXFlow -> True
    fanHere = case state.at of
        At place -> ScopedFan place.scope <$> fanNamed place.name
        Out -> Nothing
        Exit -> Nothing
    going = case (state.at, stuck state) of
        (Out, _) -> plain (Done (prUrl facts state))
        (Exit, _) -> plain (Done (prUrl facts state))
        (At _, found : _) | Ask.Stuck `notElem` state.askedHere -> plain (Ask Ask.Stuck (stuckText found))
        (At place, _) | Just _ <- choiceNamed place.name -> (atChoice place, choicePrompt place)
        (At place, _) | Just budget <- usedUpAt place, Extend <- budget.cap.atCap -> plain (extendOrGo place budget)
        (At place, _) -> case stepNamed place.name of
            Just (AnyStep _ (SomeStep s)) -> (atStep place s, promptOf (row steps s))
            Nothing -> case fanNamed place.name of
                Just fan -> plain (atFan (ScopedFan place.scope fan) facts.ended state)
                Nothing -> plain (Run (one ("state record the " <> stateNameText (placeName place) <> " fan-out's outcome") "ends the fan-out"))
    usedUpAt place = mfilter usedUp (listToMaybe [budget | (_, budget) <- budgetsAt place])
    budgetsAt place = [(metered.step, budget) | (metered, budget) <- shownBudgets g state, metered.place == place]
    {- At a choice: the user says whether to go on at a used-up budget, once;
    then each action its budget leaves, in the order the term declares them,
    extend, and enough once every child handed back.
    -}
    atChoice place = case [budget | (_, budget) <- here, usedUp budget, budget.cap.atCap == Extend] of
        used : _ | Ask.Stuck `notElem` state.askedHere -> goOn used
        used -> Run (NonEmpty.prependList ([option step | (step, budget) <- here, not (usedUp budget)] <> [extendOption | not (null used)]) (leave :| []))
      where
        here = budgetsAt place
        open = sum [budget.ledger.open | (_, budget) <- here]
        enough = EventName (placeName place) enoughOutcome
        leave = case (Map.lookup (place, enough) g.edges, open) of
            (Just edge, 0) -> recordOption enough edge
            (Just edge, _) -> (recordOption enough edge) {means = goes edge <> ", after the open ones hand back (" <> tshow open <> " open): end your turn until then"}
            (Nothing, _) -> commandOption (recordCommand enough) "leaves the choice"
        option step = maybe (commandOption (stateNameText step) "an action of the choice") (actionAt place) (stepNamed step)
    -- One line per action, so one action's task never reads as another's.
    choicePrompt place = Text.intercalate "\n" [promptOf (row steps s) | (step, _) <- budgetsAt place, Just (AnyStep _ (SomeStep s)) <- [stepNamed step]]
    actionAt :: Place -> AnyStep -> Option
    actionAt place (AnyStep _ (SomeStep s)) = case outcomes s of
        OpensChildren -> case (row steps s).runner of
            Agent (AgentRole role) _ ->
                Option
                    ("spawn a " <> role)
                    ("prompted with state brief " <> role <> " and the task below; the hook records " <> eventText (EventName (stepName s) spawnedOutcome) <> ", and its hand-back as " <> eventText (EventName (stepName s) handedBackOutcome))
                    True
            Inline -> commandOption (recordCommand (EventName (stepName s) spawnedOutcome)) "opens a child that must hand back"
        AsksOnly -> commandOption "state ask --kind <kind> <question>" "asks one question; what it prints says who answers"
        Continues _ -> NonEmpty.head (recordOutcomes g place s)
        ExitsOr _ _ -> NonEmpty.head (recordOutcomes g place s)
        Branches _ _ -> NonEmpty.head (recordOutcomes g place s)
    -- At a used-up budget the user says whether to go on, once; then extend, or leave the loop.
    extendOrGo place budget
        | Ask.Stuck `notElem` state.askedHere = goOn budget
        | otherwise = Run (someOptions (capRecords g place budget.cap.atCap))
    goOn budget = Ask Ask.Stuck (spentText budget <> ": go on?")
    {- At a used-up budget the step's question still comes first; it records
    only what the budget leaves, and an agent is not spawned to spend past it.
    -}
    atStep :: (StepSet k) => Place -> Sing (s :: k) -> Action
    atStep place s = case special s of
        Ordinary -> case ((row steps s).runner, usedUpAt place) of
            (Agent role _, Nothing) -> Spawn role Nothing
            (Agent _ _, Just _) -> Run records
            (Inline, _) -> Run records
        AsksConfirm -> if Ask.Confirm `elem` state.askedHere then Run records else Ask Ask.Confirm "the simplified plan: confirmed, or adjusted?"
        Step.AwaitsCi -> AwaitCi (maybe "the PR" urlText (prUrl facts state))
        AwaitsMerge -> atMerge records (currentFan state)
      where
        records = maybe (recordOutcomes g place s) (someOptions . capRecords g place . (.cap.atCap)) (usedUpAt place)

{- | Options the graph guarantees: a state always has an edge out, and a
used-up budget always a way on ('State.Category.Graph.RefuseWithoutWayOut').
-}
someOptions :: [Option] -> NonEmpty Option
someOptions = fromMaybe (error "no option out of a state: the graph draws none such") . NonEmpty.nonEmpty

-- | A single option.
one :: Text -> Text -> NonEmpty Option
one command means = commandOption command means :| []

-- | The budgets that hold the run, in the order they are shown.
shownBudgets :: OpenGraph -> RunState -> [(Metered, Budget)]
shownBudgets g state = sortOn (\(metered, budget) -> shownOrder metered budget.cap) (Map.toList (budgets g state))

-- | @Re-reviews: 1 of 3 used, 2 left@: what a budget spent of what the run's Fuel allows.
spentText :: Budget -> Text
spentText budget = someMeterName budget.cap.meter <> ": " <> tshow budget.ledger.spent <> left budget.allows
  where
    left = \case
        Just allows | budget.ledger.spent >= allows -> " of " <> tshow allows <> " used, none left"
        Just allows -> " of " <> tshow allows <> " used, " <> tshow (allows - budget.ledger.spent) <> " left"
        Nothing -> " used, one per group"

{- | At a fan-out: what this run does at once first - record the hand-back
of a child whose log shows it @ended@ while this run counts it running,
triage a question, then a child's stop, record a finished task's PR, resume
a child its answer waits for or a restart lost, spawn a task - then ask the
user what waits on them, then wait on CI, the children at work or a
dependency's merge. A question the user holds blocks no other child (the 10x
skill's "Other tasks keep moving"). A child the 10x resumed, or a task it spawned, has an agent at work
and is advised no more. With none at work, none spawnable and no merge
awaited, a task is left to park.
-}
atFan :: ScopedFan -> [RunId] -> RunState -> Action
atFan at ended state = fromMaybe leave (asum [unrecorded, question, triage, record, resume, spawn, awaitAnswer, awaitCi, awaitChildren, awaitMerge])
  where
    here = fanIn state.fans at
    fan = at.fan
    unrecorded = listToMaybe [Run (one ("state handback " <> roleText (taskRole task)) ("child " <> runIdText c.child.run <> " ended, its hand-back unrecorded: pipe it in")) | c <- Fan.running here, c.child.run `elem` ended, Just task <- [Fan.lookupTask here c.child.task]]
    waiting = Fan.waiting here
    open = map (.asking.question.qid) state.pending
    question = listToMaybe [Triage p.asking.question | p <- state.pending, p.waits == ForTriage]
    awaitAnswer = listToMaybe [AwaitAnswer p.asking.question | p <- state.pending, p.waits == ForAnswer]
    triage = listToMaybe [TriageStop child.run stop | (child, stop) <- Fan.untriaged here]
    record = recordFinished here
    resume = listToMaybe ([Resume c.child.run ("with the answer to " <> qidText qid) | c <- waiting, Just (AsksUp qid) <- [Fan.latest c], qid `notElem` open] <> lost)
    -- A child that never handed back and has no agent lost it at a restart: a fresh one resumes its run.
    lost = [Resume c.child.run ("lost at a restart: a fresh " <> roleText (taskRole task) <> " with its spawn prompt") | c <- waiting, not (Fan.settled here c.child.task), Nothing <- [Fan.latest c], Just task <- [Fan.lookupTask here c.child.task]]
    spawn = (\task -> Spawn (taskRole task) (Just task.id)) <$> listToMaybe (Fan.spawnable (askingChildren state) here)
    taskRole task = (Role.role task.flow).name
    awaitCi = AwaitCi . Text.unwords . NonEmpty.toList <$> NonEmpty.nonEmpty [oneLineText ref | c <- waiting, Just (AwaitsCi ref) <- [Fan.latest c]]
    awaitChildren = AwaitChildren <$> NonEmpty.nonEmpty (Set.toList here.atWork)
    awaitMerge = AwaitMerge <$> NonEmpty.nonEmpty (Fan.mergesAwaited here)
    leave = Run $ case Fan.unsettled here of
        task : _ -> one ("state record task " <> taskIdText task <> " parked <why>") "no agent works on it and none can start it: park it"
        [] -> one (recordCommand (fanEvent Leaves (qualify at.scope (namedState fan)))) "every task is settled: the fan-out ends"

{- | At a fan-out's merge: record a finished task's PR, await the unmerged,
then record the merge. With every task parked nothing merged, so the run
stops honestly instead.
-}
atMerge :: NonEmpty Option -> Fan -> Action
atMerge records fan = case (Fan.allParked fan, recordFinished fan, NonEmpty.nonEmpty (Fan.unmerged fan)) of
    (True, _, _) -> Run (one "state stop blocked \"all tasks parked\"" "nothing merged: the run stops")
    (False, Just record, _) -> record
    (False, Nothing, Just tasks) -> AwaitMerge tasks
    (False, Nothing, Nothing) -> Run records

{- | The record of a finished task's PR, for a READY whose line 1 named none
('State.Protocol.Handback' records the rest).
-}
recordFinished :: Fan -> Maybe Action
recordFinished fan = listToMaybe [Run (one (recordTask task) "its child finished: record its PR") | task <- fan.tasks, Fan.unrecorded fan task.id]

recordTask :: Task -> Text
recordTask task = "state record task " <> taskIdText task.id <> " " <> taskStateArgs (InReview (Url "<url>"))

-- | The PR's url as GitHub reports it, else the PR the run recorded.
prUrl :: Facts -> RunState -> Maybe Url
prUrl facts state = (.draft.url) <$> facts.pr <|> state.published <|> (.url) <$> state.drafted

-- | The record of each of a step's outcomes, exit first, and where it goes.
recordOutcomes :: (StepSet k) => OpenGraph -> Place -> Sing (s :: k) -> NonEmpty Option
recordOutcomes g place s =
    someOptions
        [ maybe (commandOption (recordCommand event) "") (recordOption event) (Map.lookup (place, event) g.edges)
        | outcome <- outcomeNames (outcomes s)
        , let event = EventName (placeName place) outcome
        ]

recordOne :: Text -> [Text] -> Text
recordOne event choices = "state record " <> event <> " <" <> Text.intercalate "|" choices <> ">"

stuckText :: Stuck -> Text
stuckText found =
    "the "
        <> nameText found.loop
        <> " loop repeats "
        <> Text.intercalate ", " (map problemText (Set.toList found.same))
        <> ": go on, change course, or stop?"
  where
    problemText = \case
        Row (Event.Label label) -> label
        Unmet (Requirement requirement) -> "not met: " <> requirement
        Failing (Event.Check check) -> "failing: " <> check

factLines :: OpenGraph -> Facts -> RunState -> [Text]
factLines g facts state =
    ["fuel: " <> fuelName (fuelOf state)]
        <> map (spentText . snd) (shownBudgets g state)
        <> ["changed lines: " <> tshow changed | Just changed <- [facts.changedLines]]
        <> ["PR: " <> urlText pr.draft.url <> readinessText pr.readiness | Just pr <- [facts.pr]]
        <> [taskLine fan (map (.asking.question.qid) state.pending) task | fan <- Map.elems state.fans, task <- fan.tasks]
  where
    readinessText = \case
        IsDraft -> " (draft)"
        IsReady -> " (ready)"
        IsMerged -> " (merged)"
        IsClosed -> " (closed)"

{- | A task of the 10x's breakdown: its latest child and what it said, its PR,
its tries. A child's question shows while it is open, these its ids.
-}
taskLine :: Fan -> [QId] -> Task -> Text
taskLine fan open task =
    "task "
        <> taskIdText task.id
        <> ": "
        <> Text.intercalate ", " (childText <> foldMap (pure . movedText) (Map.lookup task.id fan.moves) <> atWork <> ["tries " <> tshow (Fan.tries fan task.id)] <> held)
  where
    latestChild = listToMaybe (reverse (Fan.childrenOf fan task.id))
    childText = case latestChild of
        Nothing -> ["not started"]
        Just c -> ["child " <> runIdText c.child.run <> " " <> maybe "running" saidText (Fan.latest c)]
    -- A child that never handed back says "running" already.
    atWork = ["agent at work" | Set.member task.id fan.atWork, maybe True (isJust . Fan.latest) latestChild]
    held = ["held " <> urlText url | (heldTask, url) <- fan.held, heldTask == task.id]
    saidText = \case
        Finished summary -> "finished: " <> oneLineText summary
        AsksUp qid
            | qid `elem` open -> "asks " <> qidText qid
            | Set.member task.id fan.atWork -> "running"
            | otherwise -> "waits to resume"
        AwaitsCi ref -> "awaits CI on " <> oneLineText ref
        Ended stop -> "stopped " <> reasonText stop.reason <> ": " <> stop.why
    movedText moved =
        "PR " <> taskStateName moved <> case moved of
            InCi url -> " " <> urlText url
            InReview url -> " " <> urlText url
            Merged url -> " " <> urlText url
            Kept url -> " " <> urlText url
            Parked why pr -> foldMap ((" " <>) . urlText) pr <> ": " <> why

{- | The advice as its first line, for this principal and interface: the only
place either is read.
-}
deliver :: Start -> Action -> Text
deliver start = \case
    Spawn (AgentRole role) task -> "SPAWN " <> role <> foldMap ((" --task " <>) . taskIdText) task <> " background: " <> if has Event.Background then "yes" else "no"
    Ask kind what -> "ASK " <> kindName kind <> " " <> what
    Triage question ->
        "RUN state rule "
            <> qidText question.qid
            <> " --answer <a> --why <w> --cost <c>"
            -- 'Ask.rule' refuses a Security ruling with no basis.
            <> (if question.kind == Ask.Security then " --basis <event-id>|obvious:<why>" else "")
            <> " | state forward "
            <> qidText question.qid
            <> " - "
            <> asked question
    AwaitAnswer question -> case Ask.deliver start.principal of
        TheUser -> "ASK " <> asked question
        ParentRun _ -> "HANDBACK " <> needsDecision question
    AwaitCi ref -> (if has Event.Await then "" else "HANDBACK ") <> "AWAIT ci " <> ref
    Resume child with -> "RESUME " <> runIdText child <> " " <> with
    TriageStop child stop -> triageFrom (runIdText child) (stopLine stop)
    TriageHandback (AgentRole role) line -> triageFrom role (oneLineText line)
    AwaitChildren tasks -> "AWAIT children " <> Text.unwords (map taskIdText (toList tasks))
    AwaitMerge tasks -> "AWAIT merge " <> Text.unwords (map taskIdText (toList tasks))
    Run (option :| []) -> "RUN " <> optionCommand start option
    Run (_ :| _ : _) -> "RUN one option below"
    Stopped stop -> case Ask.deliver start.principal of
        TheUser -> "STOP " <> reasonText stop.reason <> " " <> stop.why
        ParentRun _ -> "HANDBACK " <> stopLine stop
    Done url -> case Ask.deliver start.principal of
        TheUser -> "DONE" <> foldMap ((" " <>) . urlText) url
        ParentRun _ -> "HANDBACK READY" <> foldMap ((" " <>) . urlText) url
  where
    has op = Set.member op start.interface
    triageFrom from line = "RUN state ask --kind <kind> --from " <> from <> " <question> - triage: " <> line
    asked question = kindName question.kind <> " " <> qidText question.qid <> ": " <> oneLineText question.text

-- | What @state next@ prints for a step: an agent step's lead part, then the task.
promptOf :: Row -> Text
promptOf r = case r.runner of
    Inline -> r.task
    Agent _ lead -> lead <> " " <> r.task

{- | The step's prompt text, with the notify only a run that can notify
makes: a child run's parent notifies for it.
-}
deliverPrompt :: Start -> Advice -> Text
deliverPrompt start advice
    | advice.notify && Set.member Event.Notify start.interface = advice.prompt <> " Then notify."
    | otherwise = advice.prompt

{- | The run's own question: the events to record, oldest first, and the line
saying where it goes. A question the run's row forwards is forwarded at once,
before any answer can come down.
-}
ownAsk :: RunState -> Kind -> OneLine -> (Question, [Event], Text)
ownAsk state kind text = (question, Asked (Asking question (askedAt state) Itself) : forward, line)
  where
    question = Question (nextQId state) kind text
    (forward, line) = case Ask.ask state.start.principal (flowRole state.start.flow) kind of
        AnswerSelf -> ([], "ANSWER yourself")
        Up above ->
            ( [Forwarded question.qid above]
            , case above of
                TheUser -> "ASK user"
                ParentRun _ -> "HANDBACK " <> needsDecision question
            )

{- | Where the run is, in one plain line: the state, and what it means to
an agent that knows nothing of the kernel.
-}
atLine :: Steps -> RunState -> Text
atLine steps state = case state.at of
    At place -> "at " <> stateNameText (placeName place) <> ": " <> meaning place.name
    Out -> "at the end: the flow is done"
    Exit -> "at the end: the flow is done"
  where
    meaning name = case (stepNamed name, choiceNamed name) of
        (Just (AnyStep _ (SomeStep s)), _) -> case (row steps s).runner of
            Inline -> "a step you run - do the task below, run the option that fits its result, then state next"
            Agent role _ -> "a step a " <> roleText role <> " subagent runs - spawn it with the task below; its hand-back is recorded by the hook, or by piping it into state handback " <> roleText role <> "; then state next"
        (Nothing, Just _) -> "a choice you run - take the options below one at a time, in any order, as their budgets allow; state next after each"
        (Nothing, Nothing) -> "a fan-out - its tasks run as child runs; do what the first line says, then state next"

{- | The lines under the advice's first line: where the run is, then each
option to take, or where the step's outcomes lead, one per line.
-}
explained :: Start -> Advice -> [Text]
explained start advice = advice.at : listed "options:" (runOptions advice.action) <> listed "outcomes:" advice.leads
  where
    listed _ [] = []
    listed heading options = heading : ["  " <> optionCommand start option <> " - " <> option.means | option <- options]

{- | An option's command for this interface: a spawn runs in the background
only where the interface can, as 'deliver' says of a @SPAWN@.
-}
optionCommand :: Start -> Option -> Text
optionCommand start option
    | option.spawns = option.command <> if Set.member Event.Background start.interface then " in the background" else " in the foreground"
    | otherwise = option.command

-- | The options a 'Run' offers.
runOptions :: Action -> [Option]
runOptions = \case
    Run options -> toList options
    Spawn _ _ -> []
    Ask _ _ -> []
    Triage _ -> []
    AwaitAnswer _ -> []
    AwaitCi _ -> []
    Resume _ _ -> []
    TriageStop _ _ -> []
    TriageHandback _ _ -> []
    AwaitChildren _ -> []
    AwaitMerge _ -> []
    Stopped _ -> []
    Done _ -> []
