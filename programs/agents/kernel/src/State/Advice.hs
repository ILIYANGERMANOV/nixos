{- | What a run does next, decided from its state alone (#360's @state next@).
'advise' never reads who started the run or what its interface can do (law
Principal-blind); 'deliver' alone turns the advice into the line that
principal and interface need.
-}
module State.Advice (
    Facts (..),
    PullRequest (..),
    Readiness (..),
    Advice (..),
    Action (..),
    due,
    advise,
    deliver,
    ownAsk,
    factLines,
) where

import Control.Monad (join)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import State.Ask (Above (..), Delivery (..), Kind, OneLine, Question (..), kindName, needsDecision, oneLineText, qidText)
import State.Ask qualified as Ask
import State.Cap (EventName, Outcomes (..), SomeStep (..), Step (Alternative, Confirm, Draft, Pick, Ready, Refactor, Research, SimplifyP), continueEvent, eventText, exitEvent, outcomes, skipEvent, stateNameText, stepName, stepNamed)
import State.Cap qualified as Cap
import State.Codec (judgementText, reasonText, urlText)
import State.Event (AgentRole (..), Asker (Itself), Asking (..), DraftPr (..), Event (Asked, Forwarded), Outcome (..), Requirement (..), Start (..), Stop (..), Url)
import State.Event qualified as Event
import State.Flow (LoopId (..), loopName)
import State.Fold (Pending (..), Problem (..), Round (..), RunState (..), Stuck (..), Waits (..), askedAt, budget, flowRole, mode, nextQId, stuck)
import State.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..))
import State.Handback (stopLine)
import State.Mode (Cfg (..), Mode (..), SkipWhen (..), cfg, qualityName, sizeName)
import State.Steps (Row (entry, runner), Runner (..), Steps, row)

-- | What GitHub and git say, read by the shell before it advises.
data Facts = Facts {changedLines :: Maybe Natural, pr :: Maybe PullRequest}
    deriving stock (Eq, Show)

data PullRequest = PullRequest {draft :: DraftPr, readiness :: Readiness}
    deriving stock (Eq, Show)

-- | Where the PR stands on GitHub: open as a draft or ready for review, or over.
data Readiness = IsDraft | IsReady | IsMerged | IsClosed
    deriving stock (Eq, Show)

-- | The action, the facts the reader weighs it by, and the step's entry text.
data Advice = Advice {action :: Action, facts :: [Text], entry :: Text}
    deriving stock (Eq, Show)

data Action
    = Spawn AgentRole
    | -- | A question of the run's own, for @state ask --kind@.
      Ask Kind Text
    | -- | A pending question this run rules on or forwards.
      Triage Question
    | -- | A forwarded question, until its answer comes down.
      AwaitAnswer Question
    | -- | CI on this PR.
      AwaitCi Text
    | Run Text
    | Stopped Stop
    | Done (Maybe Url)
    deriving stock (Eq, Show)

{- | The one outcome the shell records before advising, when the facts or the
mode already decide it: the draft PR or its readiness seen on GitHub, or a
skip the mode makes. The shell records it and asks again, until 'Nothing'.
-}
due :: OpenGraph -> Facts -> RunState -> Maybe Outcome
due g facts state = case (state.stopped, state.at) of
    (Nothing, At place) -> listToMaybe (fromGitHub place.name <> skipped place)
    (Nothing, Out) -> Nothing
    (Nothing, Exit) -> Nothing
    (Just _, _) -> Nothing
  where
    fromGitHub name = case facts.pr of
        Just pr
            | name == stepName Draft, open pr.readiness -> [DraftDone pr.draft]
            | name == stepName Ready, IsReady <- pr.readiness -> [ReadyDone pr.draft.url]
        _ -> []
    -- Before the run drafts, a merged or closed PR is an old one on a reused branch name: no PR.
    open = \case
        IsDraft -> True
        IsReady -> True
        IsMerged -> False
        IsClosed -> False
    skipped place =
        [ outcome
        | ((from, event), edge) <- Map.toList g.edges
        , from == place
        , Skip optId <- [edge.arrow]
        , Just why <- [skipsBecause ((cfg (mode state)).skip optId)]
        , Just outcome <- [skipOutcome facts why event]
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
skipOutcome :: Facts -> Text -> EventName -> Maybe Outcome
skipOutcome facts why event =
    join . lookup event $
        [ (skipEvent Research, Just ResearchSkipped)
        , (skipEvent SimplifyP, Just SimplifyPlanSkipped)
        , (skipEvent Alternative, Just AlternativeSkipped)
        , (skipEvent Refactor, Just (RefactorSkipped why))
        , (skipEvent Ready, (\pr -> ReadySkipped pr.draft.url) <$> facts.pr)
        ]

-- | The next action, from the run's state alone.
advise :: Steps -> Facts -> RunState -> Advice
advise steps facts state = Advice action (factLines facts state) entry
  where
    plain next = (next, "")
    (action, entry) = case (state.stopped, state.pending, state.quality, state.size) of
        (Just stop, _, _, _) -> plain (Stopped stop)
        (Nothing, oldest : _, _, _) -> plain $ case oldest.waits of
            ForTriage -> Triage oldest.asking.question
            ForAnswer -> AwaitAnswer oldest.asking.question
        (Nothing, [], Nothing, _) -> plain (Run (recordOne "quality" (map qualityName [minBound .. maxBound])))
        (Nothing, [], Just _, Nothing) -> plain (Run (recordOne "size" (map sizeName [minBound .. maxBound])))
        (Nothing, [], Just _, Just _) -> going
    going = case (state.at, stuck state) of
        (Out, _) -> plain (Done ((.draft.url) <$> facts.pr))
        (Exit, _) -> plain (Done ((.draft.url) <$> facts.pr))
        (At _, found : _) | Ask.Stuck `notElem` state.askedHere -> plain (Ask Ask.Stuck (stuckText found))
        (At place, _) -> case stepNamed place.name of
            Just (SomeStep s) -> (atStep s, (row steps s).entry)
            -- Fan-outs are the 10x's (PR 6): the engineer flow has none.
            Nothing -> plain (Run ("state record the " <> stateNameText place.name <> " fan-out's outcome"))
    atStep :: Step i e o -> Action
    atStep s = case lookup (stepName s) special of
        Just next -> next
        Nothing -> case (row steps s).runner of
            Agent role -> Spawn role
            Inline -> Run (recordOutcomes s)
    special =
        [ (stepName Confirm, if Ask.Confirm `elem` state.askedHere then Run (recordOutcomes Confirm) else Ask Ask.Confirm "the plan and its proposals: confirmed, or adjusted?")
        , (stepName Pick, Run (pickCommand state))
        , (stepName Cap.AwaitCi, AwaitCi (maybe "the PR" (\pr -> urlText pr.draft.url) facts.pr))
        ]

-- | The record line for each of a step's outcomes, exit first.
recordOutcomes :: Step i e o -> Text
recordOutcomes s = Text.intercalate " | " ["state record " <> eventText event | event <- events]
  where
    events = case outcomes s of
        Continues _ -> [continueEvent s]
        ExitsOr _ _ -> [exitEvent s, continueEvent s]

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
    loop = "state record " <> eventText (continueEvent Pick) <> picks
    final = "state record " <> eventText (exitEvent Pick) <> picks
    picks = " [--row <label>]... [--verdict <requirement>=<" <> Text.intercalate "|" (map judgementText [minBound .. maxBound]) <> ">]..."

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
  where
    readinessText = \case
        IsDraft -> " (draft)"
        IsReady -> " (ready)"
        IsMerged -> " (merged)"
        IsClosed -> " (closed)"

modeText :: Mode -> Text
modeText (Mode quality size) = qualityName quality <> " " <> sizeName size

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

{- | The advice as its first line, for this principal and interface: the only
place either is read.
-}
deliver :: Start -> Action -> Text
deliver start = \case
    Spawn (AgentRole role) -> "SPAWN " <> role <> " background: " <> if has Event.Background then "yes" else "no"
    Ask kind what -> "ASK " <> kindName kind <> " " <> what
    Triage question ->
        "RUN state rule "
            <> qidText question.qid
            <> " --answer <a> --why <w> --cost <c> | state forward "
            <> qidText question.qid
            <> " - "
            <> asked question
    AwaitAnswer question -> case Ask.deliver start.principal of
        TheUser -> "ASK " <> asked question
        ParentRun _ -> "HANDBACK " <> needsDecision question
    AwaitCi ref -> (if has Event.Await then "" else "HANDBACK ") <> "AWAIT ci " <> ref
    Run command -> "RUN " <> command
    Stopped stop -> case Ask.deliver start.principal of
        TheUser -> "STOP " <> reasonText stop.reason <> " " <> stop.why
        ParentRun _ -> "HANDBACK " <> stopLine stop
    Done url -> case Ask.deliver start.principal of
        TheUser -> "DONE" <> foldMap ((" " <>) . urlText) url
        ParentRun _ -> "HANDBACK READY" <> foldMap ((" " <>) . urlText) url
  where
    has op = Set.member op start.interface
    asked question = kindName question.kind <> " " <> qidText question.qid <> ": " <> oneLineText question.text

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
