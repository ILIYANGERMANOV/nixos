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
    heldBy,
    deliver,
    deliverMore,
    handsBack,
    deliverPrompt,
    ownAsk,
    factLines,
    childBudget,
) where

import Control.Applicative ((<|>))
import Control.Monad (mfilter)
import Data.Aeson (eitherDecodeStrictText, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Containers.ListUtils (nubOrdOn)
import Data.Foldable (asum, toList)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import Numeric.Natural (Natural)
import State.Category.Flow (FanEvent (Leaves), enoughOutcome, fanEvent, nameText, namedState, qualify, qualifyEvent)
import State.Category.Fuel (SkipWhen (..), atFuel, fuelLabel, fuelName)
import State.Category.Graph (Arrow (..), Cap (..), Edge (..), GroupAt (..), Metered (..), Node (..), OpenGraph (..), Place (..), placeName, shownOrder)
import State.Category.Meter (AtCap (Extend), Owed (..), Recorded (RecordedOutcome), owedBy, someMeterName)
import State.Category.Step (EventName (..), Sing, SomeStep (..), Special (AsksConfirm, AwaitsMerge, Ordinary, TellsResult), StepSet (..), eventText, outcomeNames, stateNameText)
import State.Category.Step qualified as Step
import State.Category.Ty (TyOf (..), TyVal)
import State.Flow.Drawn (SkipHere (..), fuelTakes, isPick, skipHere)
import State.Flow.Library (simplifyPlan)
import State.Protocol.Handback (Need (Asks), Token (NeedsDecision), TokenWord (AwaitWord, ReadyWord), stopLine, tokenLine, tokenWordText)
import State.Protocol.Record (Option (..), capRecords, commandOption, extendOption, goes, recordCommand, recordOption)
import State.Role (RoleDef (..))
import State.Role qualified as Role
import State.Run.Ask (Above (..), Delivery (..), Kind, OneLine, QId, Question (..), kindName, oneLineText, qidText, questionLine)
import State.Run.Ask qualified as Ask
import State.Run.Codec (reasonText, taskIdText, taskStateArgs, taskStateName, urlText, waitingText)
import State.Run.Event (AgentId (..), AgentRole (..), Asker (Itself), Asking (..), Branch (..), Child (..), DraftPr (..), Event (Asked, Forwarded), Requirement (..), RunId, Said (..), Start (..), Stop (..), Target (..), Task (..), TaskId, TaskState (..), Url (..), Waiting (..), roleText, runIdText)
import State.Run.Event qualified as Event
import State.Run.Fan (ChildRun (..), Fan (..))
import State.Run.Fan qualified as Fan
import State.Run.Fold (Budget (..), OnTarget (..), Pending (..), Problem (..), RunState (..), ScopedFan (..), Spent (..), Stuck (..), Waits (..), Worker (..), askedAt, askingChildren, awaitedOpen, budgets, currentFan, fanIn, fuelOf, given, nextQId, onRound, planSettled, shape, stuck, stuckExits, usedUp)
import State.Show (firstLine, tshow)
import State.Step.Build (Outcome (..), Sing (Draft))
import State.Step.Catalog (AnyOutcome (..), AnyStep (..), shownEdges, stepNamed)
import State.Step.Catalog qualified as Catalog
import State.Step.Fan (fanNamed)
import State.Step.Fuel (Sing (Fuel))
import State.Step.Plan (Outcome (..), Sing (Confirm))
import State.Step.Ship (Outcome (..), Sing (Ready))
import State.Step.Ticket (Outcome (OpenTicketDone), Sing (OpenTicket))
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

{- | The action; at a fan-out, each other task's action the run takes at
once beside it; where the run is and what that means; where the step's
outcomes lead, for an action that takes none of them itself (a spawn, a
question, CI); the facts the reader weighs it by; the step's prompt text;
and whether the step notifies the user ('deliverPrompt' decides who does).
-}
data Advice = Advice {action :: Action, more :: [Action], at :: Text, leads :: [Option], facts :: [Text], prompt :: Text, notify :: Bool}
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
    | -- | CI on this PR, or what children handed up to wait on: their refs.
      AwaitOn Waiting Text
    | -- | A child to resume, and what with: the answer to its question, or its CI.
      Resume RunId Text
    | -- | A stopped child's stop, for @state ask --from@ before any retry; its task while a retry is left, for @state retry@.
      TriageStop RunId (Maybe TaskId) Stop
    | -- | A worker's hand-back line 1, for @state ask --from@ before the run goes on.
      TriageHandback AgentRole OneLine
    | -- | A worker still at work, before the run hands back: its hand-back wakes the run.
      AwaitWorker AgentRole AgentId
    | -- | Tasks with an agent at work, none of them waiting on this run.
      AwaitChildren (NonEmpty TaskId)
    | {- | Tasks neither merged nor parked, each with its PR if one was
      recorded: the merge loop's, on approval wakes.
      -}
      AwaitMerge (NonEmpty (TaskId, Maybe Url))
    | -- | One option to take, or several to choose from.
      Run (NonEmpty Option)
    | Stopped Stop
    | Done (Maybe Url)
    deriving stock (Eq, Show)

{- | The one outcome the shell records before advising, when the facts or the
Fuel already decide it: the draft PR or its readiness seen on GitHub, a
skip the Fuel makes, the plan settled without the user, or the ticket a
request targets, at the step's scope. The shell records it and asks
again, until 'Nothing'.
-}
due :: Facts -> RunState -> Maybe Event
due facts state = case (state.stopped, state.at) of
    (Nothing, At place) -> Event.Took place.scope <$> listToMaybe (kept place.name <> decided place.name <> adopted place.name <> fromGitHub place.name <> skipped place)
    (Nothing, Out) -> Nothing
    (Nothing, Exit) -> Nothing
    (Just _, _) -> Nothing
  where
    fromGitHub name = case facts.pr of
        Just pr
            | name == stepName Draft, open pr.readiness -> [Catalog.outcome (DraftDone pr.draft)]
            | name == stepName Ready, IsReady <- pr.readiness -> [Catalog.outcome (ReadyDone pr.draft.url)]
        _ -> []
    -- A round on an existing PR leaves it as it is, at every Fuel: the run's shape skips ready,
    -- before GitHub's ready PR, which a round's PR in review is, would record it done.
    kept name = [Catalog.outcome (ReadySkipped url) | name == stepName Ready, onRound (shape state), Just url <- [prUrl facts state]]
    -- A plan its parent decided, or feedback on a target with no Design or Scope question open:
    -- the run neither simplifies nor confirms it with the user.
    decided name
        | planSettled state = [Catalog.outcome ConfirmConfirmed | name == stepName Confirm]
        | otherwise = []
    -- A request on a ticket works on that one: it opens none.
    adopted name = [Catalog.outcome (OpenTicketDone url) | name == stepName OpenTicket, Just (OnTicket url) <- [(.target) <$> state.onTarget]]
    -- Before the run drafts, a merged or closed PR is an old one on a reused branch name: no PR.
    open = \case
        IsDraft -> True
        IsReady -> True
        IsMerged -> False
        IsClosed -> False
    -- The Fuel decides a skip, or the facts at a level that skips by changed lines; a trivial task's is the agent's.
    skipped place = case skipHere place.name of
        Just skip
            | skip.block == simplifyPlan && planSettled state -> [skip.skips]
            | otherwise -> case atFuel (fuelOf state) skip.when of
                Never -> [skip.runs]
                Skippable -> []
                AtOrBelow most -> [if changed <= most then skip.skips else skip.runs | Just changed <- [facts.changedLines]]
        Nothing -> []

{- | The skips the run's Fuel leaves to the agent here, each with the record
that takes it: the agent skips the block of a trivial task and runs it
otherwise, so 'due' never records these.
-}
skippable :: RunState -> [Text]
skippable state = case (state.stopped, state.at) of
    (Nothing, At place)
        | Just skip <- skipHere place.name
        , Skippable <- atFuel (fuelOf state) skip.when ->
            [fuelLabel (fuelOf state) <> ": skip it when the task is trivial: " <> recordCommand (qualifyEvent place.scope (Catalog.outcomeEvent skip.skips))]
    _ -> []

-- | The next action, from the run's state alone.
advise :: Steps -> OpenGraph -> Facts -> RunState -> Advice
advise steps g facts state = Advice action more (atLine steps state) leads (factLines g facts state) prompt notify
  where
    plain next = (next, "")
    more = case (state.stopped, fanHere) of
        (Nothing, Just here) -> alsoAtFan here facts.ended state action
        (Nothing, Nothing) -> []
        (Just _, _) -> []
    -- Where the step's outcomes lead, for an action at a step that takes none of them itself.
    leads = case (state.stopped, state.pending, state.at, action) of
        (Nothing, [], At place, Spawn _ Nothing) -> stepLeads place
        (Nothing, [], At place, Ask Ask.Confirm _) -> stepLeads place
        (Nothing, [], At place, AwaitOn _ _) -> stepLeads place
        _ -> []
    stepLeads place = case stepNamed place.name of
        Just (AnyStep _ (SomeStep s)) ->
            ( case (row steps s).runner of
                Agent _ _ -> [commandOption (eventText event) (goes edge) | (event, edge) <- shownEdges g place, along edge]
                Inline -> [recordOption event edge | (event, edge) <- shownEdges g place, along edge]
            )
                -- The run records a stuck loop's exit itself: no worker's hand-back takes it.
                <> [recordOption event edge | (event, edge) <- stuckExits g state place, along edge]
        Nothing -> []
    along edge = case edge.arrow of
        Along _ -> True
        Stay -> False
    notify = case (state.at, Text.null prompt) of
        (At place, False) | Just (AnyStep _ (SomeStep s)) <- stepNamed place.name -> (row steps s).notifies
        _ -> False
    (action, prompt) = case (state.stopped, state.pending) of
        (Just stop, _) -> plain (Stopped stop)
        -- At a fan-out, a question waits beside the children's work: 'atFan' orders it.
        (Nothing, _ : _) | Just fan <- fanHere -> plain (atFan fan facts.ended state)
        (Nothing, oldest : _) -> plain $ case oldest.waits of
            ForTriage -> Triage oldest.asking.question
            ForAnswer -> AwaitAnswer oldest.asking.question
        (Nothing, []) -> case state.untriaged of
            (role, line) : _ -> plain (TriageHandback role line)
            [] -> going
    output = outputUrl (Role.flowOut (Role.role state.start.flow).flow) facts state
    fanHere = case state.at of
        At place -> ScopedFan place.scope <$> fanNamed place.name
        Out -> Nothing
        Exit -> Nothing
    going = case (state.at, stuck state) of
        (Out, _) -> plain (Done output)
        (Exit, _) -> plain (Done output)
        (At _, found : _) | Ask.Stuck `notElem` state.askedHere -> plain (Ask Ask.Stuck (stuckText found))
        (At place, _) | isPick place.name, Map.member (place, enoughAt place) g.edges -> (atChoice place, choicePrompt place)
        (At place, _) | isPick place.name -> (Run (someOptions [recordOption event edge | (event, edge) <- shownEdges g place]), routePrompt)
        (At _, _) | Just fan <- fanHere -> plain (atFan fan facts.ended state)
        (At place, _) | Just (Awaiting _) <- Map.lookup place g.groupStates -> plain (atAwait place)
        (At place, _) | place.name == stepName Fuel -> (atStep place Fuel, promptOf (row steps Fuel) <> fuelGiven)
        (At place, _) | Just _ <- skipHere place.name -> plain (Run (someOptions [recordOption event edge | (event, edge) <- shownEdges g place, fuelTakes (fuelOf state) place.name event]))
        (At place, _) | Just budget <- usedUpAt place, Extend <- budget.cap.atCap -> plain (extendOrGo place budget)
        (At place, _) -> case stepNamed place.name of
            Just (AnyStep _ (SomeStep s)) -> (atStep place s, promptOf (row steps s) <> told s)
            Nothing -> plain (Run (one ("state record the " <> stateNameText (placeName place) <> " state's outcome") "goes on"))
    usedUpAt place = mfilter usedUp (listToMaybe [budget | (_, budget) <- budgetsAt place])
    budgetsAt place = [(metered.step, budget) | (metered, budget) <- shownBudgets g state, metered.place == place]
    {- At a choice's pick: the user says whether to go on at a used-up
    budget, once; then each action its budget leaves, extend, and enough.
    -}
    atChoice place = case [budget | (_, budget) <- spentOn, budget.cap.atCap == Extend] of
        used : _ | Ask.Stuck `notElem` state.askedHere -> goOn used
        used -> Run (someOptions ([pickOption event edge | (event, edge) <- shownEdges g place, isNothing (usedUpOn edge)] <> [extendOption | not (null used)]))
      where
        spentOn = [(event, budget) | (event, edge) <- shownEdges g place, Just budget <- [usedUpOn edge]]
    -- An action that forks an agent's child says so, and how it runs, as a spawn's option does.
    pickOption event edge = case edge.to of
        At next
            | Just (Forking _) <- Map.lookup next g.groupStates
            , Just (AnyStep _ (SomeStep s)) <- stepNamed next.name
            , Agent (AgentRole role) _ <- (row steps s).runner ->
                (recordOption event edge) {means = goes edge <> ", which spawns a " <> role, spawns = True}
        _ -> recordOption event edge
    usedUpOn edge = case edge.to of
        At next -> usedUpAt next
        Out -> Nothing
        Exit -> Nothing
    enoughAt place = EventName (placeName place) enoughOutcome
    {- At a group's await, children are open: the run goes on by itself
    once the last hands back, so it only waits.
    -}
    atAwait place = Run (commandOption "end your turn" ("until the " <> tshow (awaitedOpen g state place) <> " open hand back: each hand-back is recorded, and the last moves the run on") :| [])
    {- Fuel is an input: the level a caller gave, or one an earlier request
    set, is recorded as given; the user is asked only when none is.
    -}
    fuelGiven = case state.fuel of
        Just level -> "\nThe Fuel given: " <> fuelName level <> ". Record it, unless the request names another."
        Nothing -> "\nNo Fuel given yet: take your brief's or the request's Fuel line; with none, ask the user once."
    -- A pick asks the user its branch at most once, and only when the request leaves it open.
    routePrompt
        | Ask.Pick `elem` state.askedHere = "The user was asked the branch once: record the branch the answer names."
        | otherwise = "Guess the branch from the request and say which you picked. Ask the user only when the request is ambiguous, once: state ask --kind Pick <question>, with your guess as the recommended option. Then record the branch."
    -- One line per action, so one action's task never reads as another's.
    choicePrompt place = Text.intercalate "\n" [promptOf (row steps s) | (_, Edge {to = At next}) <- shownEdges g place, Just (AnyStep _ (SomeStep s)) <- [stepNamed next.name]]
    told :: (StepSet k) => Sing (s :: k) -> Text
    told s = case special s of
        TellsResult -> "\nThe last result: " <> maybe "none recorded" urlText state.latest
        Ordinary -> ""
        AsksConfirm _ -> ""
        Step.AwaitsCi -> ""
        AwaitsMerge -> ""
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
        AsksConfirm what -> if Ask.Confirm `elem` state.askedHere then Run records else Ask Ask.Confirm (what <> ": confirmed, or adjusted?")
        Step.AwaitsCi -> AwaitOn Ci (maybe "the PR" urlText (prUrl facts state))
        AwaitsMerge -> atMerge records (currentFan state)
        TellsResult -> Run records
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

{- | What a child's spawn or hand-back tells under its line in place of the
advice, which parallel spawns would each repeat:

> researchers: 2 running, 3 of 5 left
> next: spawn more, or end your turn until they hand back

None for an event that opens or closes no child.
-}
childBudget :: OpenGraph -> RunState -> Event -> Maybe [Text]
childBudget g state event =
    listToMaybe
        [ childLines owed budget
        | Event.Took _ (AnyOutcome _ some) <- [event]
        , (_, budget) <- shownBudgets g state
        , Just owed <- [owedBy budget.cap.meter (RecordedOutcome some)]
        ]

childLines :: Owed -> Budget -> [Text]
childLines owed budget =
    [ Text.toLower (someMeterName budget.cap.meter) <> ": " <> howMany open <> " running" <> foldMap left budget.allows
    , "next: " <> next
    ]
  where
    open = budget.ledger.open
    left allows = ", " <> howMany (allows - min allows budget.ledger.spent) <> " of " <> tshow allows <> " left"
    howMany n = if n == 0 then "none" else tshow n
    await = "end your turn until " <> if open == 1 then "it hands back" else "they hand back"
    next = case owed of
        Opens | usedUp budget -> await
        Opens -> "spawn more, or " <> await
        Closes | open == 0 -> "state next"
        Closes -> await

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
user what waits on them, then wait on the CI or merges children handed up,
the children at work, the CI of a task's PR or a dependency's merge. A
question the user holds blocks no other child (the 10x skill's "Other tasks
keep moving"). A child the 10x resumed, or a task it spawned, has an agent at
work and is advised no more. With none at work, none spawnable and no merge
awaited, a task is left to park.
-}
atFan :: ScopedFan -> [RunId] -> RunState -> Action
atFan at ended state = fromMaybe leave (asum ([first now.unrecorded, question, first now.triage, first now.record, first now.resume, first now.spawn, awaitAnswer] <> map handedUp [minBound .. maxBound] <> [awaitChildren, awaitCi, awaitMerge]))
  where
    now = atOnce at ended state
    first = fmap snd . listToMaybe
    here = fanIn state.fans at
    fan = at.fan
    waiting = Fan.waiting here
    question = listToMaybe [Triage p.asking.question | p <- state.pending, p.waits == ForTriage]
    awaitAnswer = listToMaybe [AwaitAnswer p.asking.question | p <- state.pending, p.waits == ForAnswer]
    -- What the waiting children handed up, CI first: this run waits on it, or hands it up again.
    handedUp on = AwaitOn on . Text.unwords . NonEmpty.toList <$> NonEmpty.nonEmpty [oneLineText ref | c <- waiting, Just (Awaits awaited ref) <- [Fan.latest c], awaited == on]
    awaitChildren = AwaitChildren <$> NonEmpty.nonEmpty (Set.toList here.atWork)
    -- A task's PR in CI, a fixer's push after its child finished: the 10x records it green or parks it.
    awaitCi = AwaitOn Ci . Text.unwords . map urlText . NonEmpty.toList <$> NonEmpty.nonEmpty (Fan.ciAwaited here)
    awaitMerge = AwaitMerge <$> NonEmpty.nonEmpty (withPrs here (Fan.mergesAwaited here))
    leave = Run $ case Fan.unsettled here of
        task : _ -> one ("state record task " <> taskIdText task <> " parked <why>") "no agent works on it and none can start it: park it"
        [] -> one (recordCommand (fanEvent Leaves (qualify at.scope (namedState fan)))) "every task is settled: the fan-out ends"

{- | Each task's first action the run takes at once at a fan-out, in
'atFan''s order, but for the one 'atFan' advises: a task's line never
waits on another task's.
-}
alsoAtFan :: ScopedFan -> [RunId] -> RunState -> Action -> [Action]
alsoAtFan at ended state advised = filter (/= advised) (map snd (nubOrdOn fst (now.unrecorded <> now.triage <> now.record <> now.resume <> now.spawn)))
  where
    now = atOnce at ended state

-- | What a fan-out takes at once, each source in the breakdown's order with the task it is for.
data AtOnce = AtOnce
    { unrecorded :: [(TaskId, Action)]
    , triage :: [(TaskId, Action)]
    , record :: [(TaskId, Action)]
    , resume :: [(TaskId, Action)]
    , spawn :: [(TaskId, Action)]
    }

atOnce :: ScopedFan -> [RunId] -> RunState -> AtOnce
atOnce at ended state =
    AtOnce
        { unrecorded = [(c.child.task, Run (one ("state handback " <> roleText (taskRole task)) ("child " <> runIdText c.child.run <> " ended, its hand-back unrecorded: pipe it in"))) | c <- Fan.running here, c.child.run `elem` ended, Just task <- [Fan.lookupTask here c.child.task]]
        , triage = [(child.task, TriageStop child.run (retryable child.task) stop) | (child, stop) <- Fan.untriaged here]
        , record = recordsFinished here
        , resume = [(c.child.task, Resume c.child.run ("with the answer to " <> qidText qid <> ": " <> answer)) | (qid, answer) <- given state, Just c <- [Fan.askedBy here qid], c `elem` waiting] <> lost
        , spawn = [(task.id, Spawn (taskRole task) (Just task.id)) | task <- Fan.spawnable (askingChildren state) here]
        }
  where
    here = fanIn state.fans at
    waiting = Fan.waiting here
    -- A child that never handed back and has no agent lost it at a restart: a fresh one resumes its run.
    lost = [(c.child.task, Resume c.child.run ("lost at a restart: a fresh " <> roleText (taskRole task) <> " with its spawn prompt")) | c <- waiting, not (Fan.settled here c.child.task), Nothing <- [Fan.latest c], Just task <- [Fan.lookupTask here c.child.task]]
    taskRole task = (Role.role task.flow).name
    retryable task = if Fan.retryLeft here task then Just task else Nothing

{- | At a fan-out's merge: record a finished task's PR, await the unmerged,
then record the merge. With every task parked nothing merged, so the run
stops honestly instead.
-}
atMerge :: NonEmpty Option -> Fan -> Action
atMerge records fan = case (Fan.allParked fan, recordFinished fan, NonEmpty.nonEmpty (Fan.unmerged fan)) of
    (True, _, _) -> Run (one "state stop blocked \"all tasks parked\"" "nothing merged: the run stops")
    (False, Just record, _) -> record
    (False, Nothing, Just tasks) -> AwaitMerge (withPrs fan tasks)
    (False, Nothing, Nothing) -> Run records

-- | Each task with its PR, which a run above can wait on: it cannot read the task ids.
withPrs :: (Functor f) => Fan -> f TaskId -> f (TaskId, Maybe Url)
withPrs fan = fmap (\task -> (task, Fan.pullRequest fan task))

{- | The record of a finished task's PR, for a READY whose line 1 named none
('State.Protocol.Handback' records the rest).
-}
recordFinished :: Fan -> Maybe Action
recordFinished = fmap snd . listToMaybe . recordsFinished

-- | 'recordFinished' for each such task, in the breakdown's order.
recordsFinished :: Fan -> [(TaskId, Action)]
recordsFinished fan = [(task.id, Run (one (recordTask task) "its child finished: record its PR")) | task <- fan.tasks, Fan.unrecorded fan task.id]

recordTask :: Task -> Text
recordTask task = "state record task " <> taskIdText task.id <> " " <> taskStateArgs (InReview (Url "<url>"))

{- | The url of what the run's flow ends in, when the run keeps one: a PR's,
a ticket's, or a request's, the url recorded last. No step records a url for
any other type yet.
-}
outputUrl :: TyVal -> Facts -> RunState -> Maybe Url
outputUrl out facts state = case out of
    PR -> prUrl facts state
    Ticket -> state.ticket
    Result -> state.latest
    Ctx -> Nothing
    Plan -> Nothing
    Diff -> Nothing
    Findings -> Nothing
    List _ -> Nothing
    Sum _ -> Nothing

-- | The PR's url as GitHub reports it, else the PR the run recorded.
prUrl :: Facts -> RunState -> Maybe Url
prUrl facts state = (.draft.url) <$> facts.pr <|> state.published <|> (.url) <$> state.drafted

-- | The record of each of a step's outcomes, exit first, and where it goes.
recordOutcomes :: (StepSet k) => OpenGraph -> Place -> Sing (s :: k) -> NonEmpty Option
recordOutcomes g place s =
    someOptions
        [ maybe (commandOption (recordCommand event) "") (recordOption event) (Map.lookup (place, event) g.edges)
        | outcome <- outcomeNames (outcomes s)
        , EventName place.name outcome /= shapeSkip
        , let event = EventName (placeName place) outcome
        ]

-- | @ready.skipped@: a round's shape takes it ('due'), the fold refuses it elsewhere, so it is no option of the agent's.
shapeSkip :: EventName
shapeSkip = Catalog.outcomeEvent (Catalog.outcome (ReadySkipped (Url "")))

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
        Awaits Ci ref -> "awaits CI on " <> oneLineText ref
        Awaits Merge refs -> "awaits the merge of " <> oneLineText refs
        Ended stop -> "stopped " <> reasonText stop.reason <> ": " <> stop.why
    movedText moved =
        "PR " <> taskStateName moved <> case moved of
            InCi url -> " " <> urlText url
            InReview url -> " " <> urlText url
            Merged url -> " " <> urlText url
            Kept url -> " " <> urlText url
            Round url -> " " <> urlText url
            Parked why pr -> foldMap ((" " <>) . urlText) pr <> ": " <> why

{- | The advice held while a worker of the run is still at work and its line
would hand the run back: a lead hands back only after its workers, as a
structured-concurrency scope ends only after its children. Decided on the
delivered line, so 'advise' stays principal-blind. Names the oldest worker.
-}
heldBy :: Start -> [Worker] -> Advice -> Advice
heldBy start live advice = case live of
    worker : _
        | handsBack (deliver start advice.action) ->
            advice {action = AwaitWorker worker.role worker.agent, more = [], leads = [], facts = stillAtWork worker <> advice.facts}
    _ -> advice
  where
    stillAtWork worker =
        [ "state handback: " <> roleText worker.role <> " " <> worker.agent.agentIdText <> " is still at work - its hand-back is not recorded"
        , "fix: wait for it, or state handback " <> roleText worker.role <> " for its report, or state void " <> tshow worker.spawnedAt <> " \"<why>\" for a lost one"
        ]

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
            <> questionLine question
    AwaitAnswer question -> case Ask.deliver start.principal of
        TheUser -> "ASK " <> questionLine question
        ParentRun _ -> "HANDBACK " <> tokenLine (NeedsDecision (Asks question))
    AwaitOn waiting refs -> awaiting waiting refs
    Resume child with -> "RESUME " <> runIdText child <> " " <> with
    TriageStop child task stop -> "RUN " <> foldMap (\t -> "state retry " <> taskIdText t <> " --why <w> | ") task <> askFrom (runIdText child) (stopLine stop)
    TriageHandback (AgentRole role) line -> "RUN " <> askFrom role (oneLineText line)
    AwaitWorker role agent -> await <> " worker " <> roleText role <> " " <> agent.agentIdText
    AwaitChildren tasks -> await <> " children " <> Text.unwords (map taskIdText (toList tasks))
    -- Task ids mean nothing above this run: it hands up the PRs.
    AwaitMerge tasks
        | has Event.Await -> awaiting Merge (Text.unwords (map (taskIdText . fst) (toList tasks)))
        | otherwise -> awaiting Merge (Text.unwords [maybe (taskIdText task) urlText pr | (task, pr) <- toList tasks])
    Run (option :| []) -> "RUN " <> option.command
    Run (_ :| _ : _) -> "RUN one option below"
    Stopped stop -> case Ask.deliver start.principal of
        TheUser -> "STOP " <> reasonText stop.reason <> " " <> stop.why
        ParentRun _ -> "HANDBACK " <> stopLine stop
    Done url -> case Ask.deliver start.principal of
        TheUser -> "DONE" <> foldMap ((" " <>) . urlText) url
        ParentRun _ -> "HANDBACK " <> tokenWordText ReadyWord <> foldMap ((" " <>) . urlText) url
  where
    has op = Set.member op start.interface
    -- A run that cannot be woken hands the wait up to the run above (#360's AWAIT).
    awaiting waiting refs = (if has Event.Await then "" else "HANDBACK ") <> await <> " " <> waitingText waiting <> " " <> refs
    await = tokenWordText AwaitWord
    askFrom from line = "state ask --kind <kind> --from " <> from <> " <question> - triage: " <> line

{- | The unindented lines after the advice's first: each other action it
takes at once, none when the first hands the run back, which ends its turn.
-}
deliverMore :: Start -> Advice -> [Text]
deliverMore start advice
    | handsBack (deliver start advice.action) = []
    | otherwise = map (deliver start) advice.more

-- | A delivered line that hands the run back to its parent.
handsBack :: Text -> Bool
handsBack = ("HANDBACK " `Text.isPrefixOf`)

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
    (forward, line) = case Ask.ask state.start.principal (Role.rungAt state.start.flow (askedAt state)) kind of
        AnswerSelf -> ([], "ANSWER yourself")
        Up above ->
            ( [Forwarded question.qid above]
            , case above of
                TheUser -> "ASK user"
                ParentRun _ -> "HANDBACK " <> tokenLine (NeedsDecision (Asks question))
            )

{- | Where the run is, in one plain line: the state, and what it means to
an agent that knows nothing of the kernel.
-}
atLine :: Steps -> RunState -> Text
atLine steps state = case state.at of
    At place -> "at " <> stateNameText (placeName place) <> ": " <> meaning place
    Out -> "at the end: the flow is done"
    Exit -> "at the end: the flow is done"
  where
    meaning place
        | isPick place.name = "a branch you pick - take one option below, then state next"
        | Just _ <- skipHere place.name = "an optional block - take one option below, then state next"
        | otherwise = case stepNamed place.name of
            Just (AnyStep _ (SomeStep s)) -> case (row steps s).runner of
                Inline -> "a step you run - do the task below, run the option that fits its result, then state next"
                Agent role _ -> "a step a " <> roleText role <> " subagent runs - spawn it with the task below; its hand-back is recorded by the hook, or by piping it into state handback " <> roleText role <> "; then state next"
            Nothing -> "children at work - each runs on its own; do what each unindented line says, then state next"

{- | The lines under the advice's first line: where the run is, then each
option to take, or where the step's outcomes lead, one per line.
-}
explained :: Start -> Advice -> [Text]
explained start advice = advice.at : listed "options:" (runOptions advice.action) <> listed "outcomes:" advice.leads
  where
    listed _ [] = []
    listed heading options = heading : ["  " <> option.command <> " - " <> optionMeans start option | option <- options]

{- | What an option means for this interface: a spawn runs in the background
only where the interface can, as 'deliver' says of a @SPAWN@.
-}
optionMeans :: Start -> Option -> Text
optionMeans start option
    | option.spawns = option.means <> if Set.member Event.Background start.interface then " in the background" else " in the foreground"
    | otherwise = option.means

-- | The options a 'Run' offers.
runOptions :: Action -> [Option]
runOptions = \case
    Run options -> toList options
    Spawn _ _ -> []
    Ask _ _ -> []
    Triage _ -> []
    AwaitAnswer _ -> []
    AwaitOn _ _ -> []
    Resume _ _ -> []
    TriageStop {} -> []
    TriageHandback _ _ -> []
    AwaitWorker _ _ -> []
    AwaitChildren _ -> []
    AwaitMerge _ -> []
    Stopped _ -> []
    Done _ -> []
