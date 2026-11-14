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
    due,
    advise,
    deliver,
    deliverPrompt,
    ownAsk,
    factLines,
) where

import Control.Applicative ((<|>))
import Control.Monad (join)
import Data.Aeson (eitherDecodeStrictText, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Foldable (asum, toList)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import Numeric.Natural (Natural)
import State.Category.Flow (FanEvent (Leaves), FanId, LoopId (..), fanEvent, fanName, fanNamed, loopName)
import State.Category.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..))
import State.Category.Mode (Cfg (..), Mode (..), SkipWhen (..), cfg, qualityName, sizeName)
import State.Category.Step (EventName (..), Sing, SomeStep (..), Special (AsksConfirm, AwaitsMerge, Ordinary, PicksRows), StepSet (..), builtEvent, continueEvent, exitEvent, outcomeNames, stateNameText)
import State.Category.Step qualified as Step
import State.Protocol.Handback (readyState, stopLine)
import State.Protocol.Record (recordCommand)
import State.Run.Ask (Above (..), Delivery (..), Kind, OneLine, QId, Question (..), kindName, needsDecision, oneLineText, qidText)
import State.Run.Ask qualified as Ask
import State.Run.Codec (reasonText, taskIdText, taskStateArgs, taskStateName, urlText)
import State.Run.Event (AgentRole (..), Asker (Itself), Asking (..), Branch (..), Child (..), DraftPr (..), Event (Asked, Forwarded), Requirement (..), RunId, Said (..), Start (..), Stop (..), Task (..), TaskId, TaskState (..), Url (..), fanRole, runIdText)
import State.Run.Event qualified as Event
import State.Run.Fan (ChildRun (..), Fan (..))
import State.Run.Fan qualified as Fan
import State.Run.Fold (Pending (..), Problem (..), Round (..), RunState (..), Stuck (..), Waits (..), askedAt, askingChildren, budget, flowRole, mode, nextQId, stuck)
import State.Show (firstLine, tshow)
import State.Step.Build (Outcome (..), Sing (Draft))
import State.Step.Catalog (AnyOutcome, AnyStep (..), stepNamed)
import State.Step.Catalog qualified as Catalog
import State.Step.Fan (Outcome (..))
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..))
import State.Step.Review qualified as Review
import State.Step.Ship (Outcome (..), Sing (Ready))
import State.Table (Row (notifies, runner, task), Runner (..), Steps, row)

-- | What GitHub and git say, read by the shell before it advises.
data Facts = Facts {changedLines :: Maybe Natural, pr :: Maybe PullRequest}
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

{- | The action, the facts the reader weighs it by, the step's prompt text,
and whether the step notifies the user ('deliverPrompt' decides who does).
-}
data Advice = Advice {action :: Action, facts :: [Text], prompt :: Text, notify :: Bool}
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
    | Run Text
    | Stopped Stop
    | Done (Maybe Url)
    deriving stock (Eq, Show)

{- | The one outcome the shell records before advising, when the facts or the
mode already decide it: the draft PR or its readiness seen on GitHub, or a
skip the mode makes. The shell records it and asks again, until 'Nothing'.
-}
due :: OpenGraph -> Facts -> RunState -> Maybe AnyOutcome
due g facts state = case (state.stopped, state.at) of
    (Nothing, At place) -> listToMaybe (fromGitHub place.name <> skipped place <> leaves place)
    (Nothing, Out) -> Nothing
    (Nothing, Exit) -> Nothing
    (Just _, _) -> Nothing
  where
    fromGitHub name = case facts.pr of
        Just pr
            | name == stepName Draft, open pr.readiness -> [Catalog.outcome (DraftDone pr.draft)]
            | name == stepName Ready, IsReady <- pr.readiness -> [Catalog.outcome (ReadyDone pr.draft.url)]
        _ -> []
    -- Before the run drafts, a merged or closed PR is an old one on a reused branch name: no PR.
    open = \case
        IsDraft -> True
        IsReady -> True
        IsMerged -> False
        IsClosed -> False
    -- Every task settled: the fan-out is done, as GitHub's facts are recorded, with no one to run.
    leaves place = [Catalog.outcome (FanDone fan) | Just fan <- [fanNamed place.name], Right () <- [Fan.leave state.fanOut]]
    skipped place =
        [ outcome
        | ((from, event), edge) <- Map.toList g.edges
        , from == place
        , Skip optId <- [edge.arrow]
        , Just why <- [skipsBecause ((cfg (mode state)).skip optId)]
        , Just outcome <- [skipOutcome facts state why event]
        ]
    skipsBecause = \case
        Never -> Nothing
        Always -> Just (modeText (mode state) <> " skips it")
        AtOrBelow most -> case facts.changedLines of
            Just changed | changed <= most -> Just (tshow changed <> " changed lines, at or below " <> tshow most)
            _ -> Nothing

{- | The outcome a skip appends. @simplify_pr@ has none here: no mode skips
it, and its skip names a head these facts lack.
-}
skipOutcome :: Facts -> RunState -> Text -> EventName -> Maybe AnyOutcome
skipOutcome facts state why event =
    join . lookup event $
        map
            stated
            [ Catalog.outcome ResearchSkipped
            , Catalog.outcome SimplifyPlanSkipped
            , Catalog.outcome (RefactorSkipped why)
            ]
            <> [(builtEvent Ready ReadySkipped, Catalog.outcome . ReadySkipped <$> prUrl facts state)]
  where
    stated skip = (Catalog.outcomeEvent skip, Just skip)

-- | The next action, from the run's state alone.
advise :: Steps -> Facts -> RunState -> Advice
advise steps facts state = Advice action (factLines facts state) prompt notify
  where
    plain next = (next, "")
    notify = case (state.at, Text.null prompt) of
        (At place, False) | Just (AnyStep _ (SomeStep s)) <- stepNamed place.name -> (row steps s).notifies
        _ -> False
    (action, prompt) = case (state.stopped, state.pending, state.quality, state.size) of
        (Just stop, _, _, _) -> plain (Stopped stop)
        -- At a fan-out, a question waits beside the children's work: 'atFan' orders it.
        (Nothing, _ : _, Just _, Just _) | Just fan <- fanHere -> plain (atFan fan state)
        (Nothing, oldest : _, _, _) -> plain $ case oldest.waits of
            ForTriage -> Triage oldest.asking.question
            ForAnswer -> AwaitAnswer oldest.asking.question
        (Nothing, [], Nothing, _) -> plain (Run (recordOne "quality" (map qualityName [minBound .. maxBound])))
        (Nothing, [], Just _, Nothing) -> plain (Run (recordOne "size" (map sizeName [minBound .. maxBound])))
        (Nothing, [], Just _, Just _) -> case state.untriaged of
            (role, line) : _ -> plain (TriageHandback role line)
            [] -> going
    fanHere = case state.at of
        At place -> fanNamed place.name
        Out -> Nothing
        Exit -> Nothing
    going = case (state.at, stuck state) of
        (Out, _) -> plain (Done (prUrl facts state))
        (Exit, _) -> plain (Done (prUrl facts state))
        (At _, found : _) | Ask.Stuck `notElem` state.askedHere -> plain (Ask Ask.Stuck (stuckText found))
        (At place, _) -> case stepNamed place.name of
            Just (AnyStep _ (SomeStep s)) -> (atStep s, promptOf (row steps s))
            Nothing -> case fanNamed place.name of
                Just fan -> plain (atFan fan state)
                Nothing -> plain (Run ("state record the " <> stateNameText place.name <> " fan-out's outcome"))
    atStep :: (StepSet k) => Sing (s :: k) -> Action
    atStep s = case special s of
        Ordinary -> case (row steps s).runner of
            Agent role _ -> Spawn role Nothing
            Inline -> Run (recordOutcomes s)
        AsksConfirm -> if Ask.Confirm `elem` state.askedHere then Run (recordOutcomes s) else Ask Ask.Confirm "the simplified plan: confirmed, or adjusted?"
        PicksRows -> Run (pickCommand state)
        Step.AwaitsCi -> AwaitCi (maybe "the PR" urlText (prUrl facts state))
        AwaitsMerge -> fromMaybe (maybe (Run (recordOutcomes s)) AwaitMerge (NonEmpty.nonEmpty (Fan.unmerged state.fanOut))) (recordFinished state.fanOut)

{- | At a fan-out: what this run does at once first - triage a question, then
a child's stop, record a finished task's PR, resume a child its answer waits
for, spawn a task with a free slot - then ask the user what waits on them,
then wait on CI or the children at work. A question the user holds blocks
no other child (the 10x skill's "Other tasks keep moving"). A child the 10x
resumed, or a task it spawned, has an agent at work and is advised no more.
With none at work and none spawnable, a task is left to park.
-}
atFan :: FanId -> RunState -> Action
atFan fan state = fromMaybe leave (asum [question, triage, record, resume, spawn, awaitAnswer, awaitCi, awaitChildren])
  where
    waiting = Fan.waiting state.fanOut
    open = map (.asking.question.qid) state.pending
    question = listToMaybe [Triage p.asking.question | p <- state.pending, p.waits == ForTriage]
    awaitAnswer = listToMaybe [AwaitAnswer p.asking.question | p <- state.pending, p.waits == ForAnswer]
    triage = listToMaybe [TriageStop child.run stop | (child, stop) <- Fan.untriaged state.fanOut]
    record = recordFinished state.fanOut
    resume = listToMaybe [Resume c.child.run ("with the answer to " <> qidText qid) | c <- waiting, Just (AsksUp qid) <- [Fan.latest c], qid `notElem` open]
    spawn = (\task -> Spawn (fanRole fan) (Just task.id)) <$> listToMaybe (Fan.spawnable (askingChildren state) ((cfg (mode state)).fan fan) state.fanOut)
    awaitCi = AwaitCi . Text.unwords . NonEmpty.toList <$> NonEmpty.nonEmpty [oneLineText ref | c <- waiting, Just (AwaitsCi ref) <- [Fan.latest c]]
    awaitChildren = AwaitChildren <$> NonEmpty.nonEmpty (Set.toList state.fanOut.atWork)
    leave = Run $ case Fan.unsettled state.fanOut of
        task : _ -> "state record task " <> taskIdText task <> " parked <why>"
        [] -> recordCommand (fanEvent Leaves (fanName fan))

{- | The record of a finished task's PR, for a READY whose line 1 named none
('State.Protocol.Handback' records the rest): a POC task's stays a draft, parked.
-}
recordFinished :: Fan -> Maybe Action
recordFinished fan = listToMaybe [Run (recordTask task) | task <- fan.tasks, Fan.unrecorded fan task.id]

recordTask :: Task -> Text
recordTask task = "state record task " <> taskIdText task.id <> " " <> taskStateArgs (readyState task.quality (Url "<url>"))

-- | The PR's url as GitHub reports it, else the draft the run recorded: a POC run offline still skips ready.
prUrl :: Facts -> RunState -> Maybe Url
prUrl facts state = (.draft.url) <$> facts.pr <|> state.published <|> (.url) <$> state.drafted

-- | The record line for each of a step's outcomes, exit first.
recordOutcomes :: (StepSet k) => Sing (s :: k) -> Text
recordOutcomes s = Text.intercalate " | " [recordCommand (EventName (stepName s) outcome) | outcome <- outcomeNames (outcomes s)]

recordOne :: Text -> [Text] -> Text
recordOne event choices = "state record " <> event <> " <" <> Text.intercalate "|" choices <> ">"

{- | Pick takes @pick.loop@ only while the review loop has a round left by
'budget'. At the fuel, a Not met in this round's picks buys one more; past
it, only @pick.final@.
-}
pickCommand :: RunState -> Text
pickCommand state
    | done < budget fuel (Round Set.empty) = Text.intercalate " | " [loop, final]
    | done < budget fuel (Round (Set.singleton (Unmet anyRequirement))) =
        final <> " | " <> loop <> " only with a not-met verdict: the last round"
    | otherwise = final <> " - no review round is left"
  where
    done = maybe 1 (fromIntegral . length) (Map.lookup LReview state.rounds)
    fuel = (cfg (mode state)).fuel LReview
    -- Any requirement: 'budget' asks only whether one is Not met.
    anyRequirement = Requirement ""
    loop = recordCommand (continueEvent Review.Pick)
    final = recordCommand (exitEvent Review.Pick)

stuckText :: Stuck -> Text
stuckText found =
    "the "
        <> loopName found.loop
        <> " loop repeats "
        <> Text.intercalate ", " (map problemText (Set.toList found.same))
        <> ": go on, change course, or stop?"
  where
    problemText = \case
        Row (Event.Label label) -> label
        Unmet (Requirement requirement) -> "not met: " <> requirement
        Failing (Event.Check check) -> "failing: " <> check

factLines :: Facts -> RunState -> [Text]
factLines facts state =
    ["mode: " <> modeText (mode state)]
        <> [ loopName loopId <> " round " <> tshow (length rounds) <> " of " <> tshow ((cfg (mode state)).fuel loopId)
           | (loopId, rounds) <- Map.toList (Map.map NonEmpty.toList state.rounds)
           ]
        <> ["changed lines: " <> tshow changed | Just changed <- [facts.changedLines]]
        <> ["PR: " <> urlText pr.draft.url <> readinessText pr.readiness | Just pr <- [facts.pr]]
        <> map (taskLine state.fanOut (map (.asking.question.qid) state.pending)) state.fanOut.tasks
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
            Parked why pr -> foldMap ((" " <>) . urlText) pr <> ": " <> why

modeText :: Mode -> Text
modeText (Mode quality size) = qualityName quality <> " " <> sizeName size

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
    Run command -> "RUN " <> command
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
    Mode _ size = mode state
    (forward, line) = case Ask.ask state.start.principal size (flowRole state.start.flow) kind of
        AnswerSelf -> ([], "ANSWER yourself")
        Up above ->
            ( [Forwarded question.qid above]
            , case above of
                TheUser -> "ASK user"
                ParentRun _ -> "HANDBACK " <> needsDecision question
            )
