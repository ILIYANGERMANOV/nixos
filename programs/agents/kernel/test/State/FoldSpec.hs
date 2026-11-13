module State.FoldSpec (spec) where

import Data.Either (isRight)
import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, PropertyT, annotate, assert, cover, evalEither, evalMaybe, failure, forAll, (/==), (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Ask (Above (..), Basis (..), Choice (..), Kind (Design, Fact, Pick, Security), Proposal (..), QId (..), Question (..), Reading (..), Refusal (MayNotRule, MustAnswer, NoBasis), Role (Engineer), deliver, handback, oneLineText, qidText)
import State.Event
import State.EventGen (genOneLine, genProposal, genQuestion, genReading, genText, hookLine, line, lineOf, logOf, oneLine, outcomeNames, run, runId, started, tasksOf)
import State.Fan qualified as Fan
import State.Flow (FanId (..), LoopId (..), OptId (..))
import State.FlowGen (composes, genWalk)
import State.Fold hiding (Answer (..))
import State.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..))
import State.Mode (Cfg (..), Mode (..), Quality (..), Size (..), cfg)
import State.Path (ty)
import State.RunGen (childOf, commit, g, genAccepted, genKnobs, happyPath, outcomeOf, plainTask, sha, tenXGraph)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Fold" $ do
    it "names every edge of the engineer and 10x flows by exactly one kind of outcome" $
        outcomeNames `shouldBe` Set.fromList [name | flow <- [g, tenXGraph], ((_, name), edge) <- Map.toList flow.edges, edge.arrow /= Stay]

    describe "the 10x's fan-out" $ do
        let tenXRun events = replay tenXGraph (logOf (Started (startOf TenXFlow ByUser) :| events))
            toEngineers = [Overridden (StateName "breakdown") "the plan is agreed", Took (BreakdownDone (tasksOf (plainTask "t1" [] :| [])))]
            child = childOf "c1" "t1"
            atName state = case state.at of
                At place -> Just place.name
                Out -> Nothing
                Exit -> Nothing
        it "refuses a child's spawn outside the fan-out" $
            tenXRun [Spawned child] `shouldSatisfy` \case
                Left (NoEdge _ _) -> True
                _ -> False
        it "logs a child's spawn and hand-back at the fan-out, staying there" $
            atName <$> tenXRun (toEngineers <> [Spawned child, HandedBack (runId "c1") (AsksUp (QId (runId "c1") 1))])
                `shouldBe` Right (Just (StateName "engineers"))
        it "refuses to leave the fan-out while a task is unsettled" $
            tenXRun (toEngineers <> [Spawned child, Took (FanDone FEngineers)])
                `shouldBe` Left (FanRefused (Fan.Unsettled (TaskId "t1" :| [])))
        it "leaves the fan-out for the merge once every task is settled" $
            atName <$> tenXRun (toEngineers <> [Spawned child, HandedBack (runId "c1") (Finished (oneLine "PR #1")), Took (FanDone FEngineers)])
                `shouldBe` Right (Just (StateName "merge"))
        it "refuses a task the breakdown lacks" $
            tenXRun (toEngineers <> [Held (TaskId "t9") (Url "u")]) `shouldBe` Left (FanRefused (Fan.UnknownTask (TaskId "t9")))

    it "runs the engineer flow's happy path to its end" $
        (.at) <$> replay g (logOf (started :| map Took happyPath)) `shouldBe` Right Out

    it "every_accepted_log_is_a_path" . hedgehog $ do
        events <- forAll genCandidate
        case replay g (logOf (started :| events)) of
            Left _ -> cover 10 "refused" True
            Right state -> do
                cover 20 "accepted" True
                cover 5 "reached the end" (state.at == Out)
                path <- evalMaybe (ty g [outcomeEvent outcome | Took outcome <- events])
                assert (composes path)

    it "rounds_never_exceed_fuel_plus_one" . hedgehog $ do
        events <- forAll genAccepted
        states <- traverse (evalEither . replay g . logOf) (NonEmpty.toList (NonEmpty.inits1 (started :| events)))
        let reached = [(loopId, rounds, state) | state <- states, (loopId, rounds) <- Map.toList state.rounds]
        cover 1 "a loop past its fuel" (any (\(l, rs, s) -> length rs > fuel s l) reached)
        sequence_
            [ do
                assert (length rounds <= fuel state loopId + 1)
                assert (length rounds <= fuel state loopId || unmetIn (NonEmpty.toList rounds !! (fuel state loopId - 1)))
            | (loopId, rounds, state) <- reached
            ]

    -- At the pick, before the fixer runs, so the run can still take the loop's exit.
    it "refuses a review round past the fuel at the loop pick" $
        replay g (logOf (started :| QualitySet Balanced : SizeSet Trivial : toReview <> reviewRound []))
            `shouldBe` Left (OutOfFuel LReview 1)

    it "gives one more round after a Not met at the fuel, never two" $ do
        let unmet = Picks Set.empty (Map.singleton (Requirement "R1") NotMet)
            once = toReview <> roundWith unmet <> [Took (FixDone commit), Took (ReviewRows sha)]
        (.at) <$> replay g (logOf (started :| SizeSet Trivial : once)) `shouldSatisfy` either (const False) (/= Out)
        replay g (logOf (started :| SizeSet Trivial : once <> [Took (PickLoop unmet)])) `shouldBe` Left (OutOfFuel LReview 1)

    it "stuck_after_two_same_rounds" . hedgehog $ do
        -- Max's 6 rounds: the last round's loop pick is refused, as no round is left.
        rows <- forAll (Gen.list (Range.linear 1 5) (Gen.subsequence ["A", "B", "C"]))
        state <- evalEither (replay g (logOf (started :| QualitySet Max : toReview <> reviewRounds rows)))
        let expected = case reverse rows of
                current : previous : _ -> Set.map (Row . Label) (Set.fromList current `Set.intersection` Set.fromList previous)
                _ -> Set.empty
        cover 10 "stuck" (not (Set.null expected))
        stuck state === [Stuck LReview expected | not (Set.null expected)]

    it "is not stuck on rows alternating A, B, A, B: only rounds in a row count" $
        stuck <$> replay g (logOf (started :| QualitySet Max : toReview <> reviewRounds [["A"], ["B"], ["A"], ["B"]]))
            `shouldBe` Right []

    it "is stuck on one failing check in two CI rounds in a row" $ do
        let red = Took (AwaitCiRed sha (Check "lint" :| []))
        stuck <$> replay g (logOf (started :| toCi <> [red, Took (FixPrDone sha), red]))
            `shouldBe` Right [Stuck LCi (Set.singleton (Failing (Check "lint")))]

    it "forgets a loop's rounds once the run leaves it" $
        stuck <$> replay g (logOf (started :| QualitySet Max : toReview <> reviewRounds [["A"], ["A"]] <> [Took (FixDone commit), Took (ReviewClean sha)]))
            `shouldBe` Right []

    it "restarts gathering in each round of the plan loop" $ do
        let gather = [ResearchDone 1, InterviewMore]
            gathered = concat (replicate 5 gather) <> [ResearchDone 1, InterviewEnough, PlanDone "p", SimplifyPlanDone, AlternativeDone, ConfirmAdjusted] <> gather
        Map.map length . (.rounds) <$> replay g (logOf (started :| map Took gathered))
            `shouldBe` Right (Map.fromList [(LGather, 2), (LPlan, 2)])

    it "append_is_idempotent_by_id" . hedgehog $ do
        events <- forAll genAccepted
        let logged = logOf (started :| events)
        state <- evalEither (replay g logged)
        again <- forAll (Gen.element (NonEmpty.toList logged))
        append g state again === Right AlreadyLogged

    it "logs a hook record fired twice once" $ do
        let hook n = hookLine "ab12" n (Took (ResearchDone 1))
        (.at) <$> replay g (line 0 started :| [hook 1, hook 2]) `shouldBe` (.at) <$> replay g (line 0 started :| [hook 1])

    it "state_is_a_fold" . hedgehog $ do
        events <- forAll genAccepted
        split <- forAll (Gen.int (Range.linear 1 (length events + 1)))
        let (before, after) = NonEmpty.splitAt split (logOf (started :| events))
        firstPart <- evalMaybe (NonEmpty.nonEmpty before)
        (replay g firstPart >>= \state -> fold g state after) === replay g (logOf (started :| events))

    it "refuses a log whose first line is not started" $
        replay g (logOf (Took (ResearchDone 1) :| [])) `shouldBe` Left NotStarted

    it "refuses an event with no edge where the run is" $
        replay g (logOf (started :| [Took (ReviewClean sha)])) `shouldBe` Left (NoEdge (At research) (outcomeEvent (ReviewClean sha)))

    it "refuses a skip the mode never takes" $
        replay g (logOf (started :| [Took ResearchSkipped])) `shouldBe` Left (NotSkippable ORes)

    it "takes a skip where the mode does" $
        (.at) <$> replay g (logOf (started :| [SizeSet Trivial, Took ResearchSkipped])) `shouldSatisfy` either (const False) (/= At research)

    it "refuses a second Quality" $
        replay g (logOf (started :| [QualitySet Max, QualitySet Poc])) `shouldBe` Left (QualitySetOnce Max)

    it "refuses a second Size" $
        replay g (logOf (started :| [SizeSet Trivial, SizeSet Normal])) `shouldBe` Left (SizeSetOnce Trivial)

    it "takes the same Quality again, and a Size that grew" $
        mode <$> replay g (logOf (started :| [QualitySet Max, QualitySet Max, SizeSet Trivial, Grew "bigger"])) `shouldBe` Right (Mode Max Normal)

    it "takes no event after a stop" $
        replay g (logOf (started :| [Stopped stop, Took (ResearchDone 1)])) `shouldBe` Left (AfterStop stop)

    it "logs a refusal after a stop" $
        (.refused) <$> replay g (logOf (started :| [Stopped stop, Refused note])) `shouldBe` Right (Just note)

    it "warns of a refusal until the next event" $
        (.refused) <$> replay g (logOf (started :| [Refused note, Took (ResearchDone 1)])) `shouldBe` Right Nothing

    it "refuses a line of another run" $
        replay g (line 0 started :| [ofRun (runId "other") (line 1 (Took (ResearchDone 1)))]) `shouldBe` Left (OtherRun (runId "other"))

    it "overrides to a named state" $
        placeName . (.at) <$> replay g (logOf (started :| [Overridden (StateName "review") "why"])) `shouldBe` Right (Just (StateName "review"))

    it "refuses an override to a state the flow does not have" $
        replay g (logOf (started :| [Overridden (StateName "nowhere") "why"])) `shouldBe` Left (NoSingleState (StateName "nowhere"))

    questions
  where
    note = Note "no edge" "state next"
    stop = Stop Blocked "why"

research :: Place
research = g.inPort

ofRun :: RunId -> Envelope -> Envelope
ofRun other (Envelope source n ts _ sha' session event) = Envelope source n ts other sha' session event

placeName :: Node -> Maybe StateName
placeName = \case
    At place -> Just place.name
    Out -> Nothing
    Exit -> Nothing

-- | From the start to the first review.
toReview :: [Event]
toReview = map Took (take 9 happyPath)

-- | From the start to the first CI result.
toCi :: [Event]
toCi = map Took (take 9 happyPath <> [ReviewClean sha, DescribeDone sha, SimplifyPrDone sha])

reviewRound :: [Label] -> [Event]
reviewRound rows = roundWith (Picks (Set.fromList rows) Map.empty)

roundWith :: Picks -> [Event]
roundWith picks = [Took (ReviewRows sha), Took (PickLoop picks)]

-- | Review rounds with these rows, fixed between rounds; the last ends at its picks.
reviewRounds :: [[Text]] -> [Event]
reviewRounds = \case
    [] -> []
    [rows] -> reviewRound (map Label rows)
    rows : rest -> reviewRound (map Label rows) <> [Took (FixDone commit)] <> reviewRounds rest

fuel :: RunState -> LoopId -> Int
fuel state loopId = fromIntegral ((cfg (mode state)).fuel loopId)

unmetIn :: Round -> Bool
unmetIn (Round problems) = any (\case Unmet _ -> True; Row _ -> False; Failing _ -> False) problems

-- | Any mode, then a walk to the end, sometimes with an event from anywhere in the flow.
genCandidate :: Gen [Event]
genCandidate = do
    knobs <- genKnobs
    walk <- genWalk g
    noise <- Gen.element (Set.toList outcomeNames)
    at <- Gen.int (Range.linear 0 (length walk))
    names <- Gen.element [walk, take at walk <> [noise] <> drop at walk]
    outcomes <- traverse outcomeOf names
    pure (knobs <> map Took outcomes)

-- | The ask events, on the engineer flow's graph: they never move the run.
questions :: Spec
questions = describe "questions" $ do
    it "keeps a question pending, oldest first, until it is ruled on or its answer comes down" $
        map (\pending -> (pending.asking.question.qid, pending.waits)) . (.pending)
            <$> replay g (logOf (started :| [ask 3 Design, ask 1 Design, ask 2 Pick, ask 4 Design, RuledOn (q 2) proposal, Forwarded (q 1) TheUser, Forwarded (q 4) TheUser, Answered (q 4) "yes" TheUser]))
            `shouldBe` Right [(q 3, ForTriage), (q 1, ForAnswer)]

    it "keeps the run at its step while a question waits, the step named in the log (law Resume)" $
        ((.at) <$> replay g (logOf (started :| [ask 1 Design, Forwarded (q 1) TheUser])), map (.asking.step) . (.pending) <$> replay g (logOf (started :| [ask 1 Design])))
            `shouldBe` ((.at) <$> replay g (logOf (started :| [])), Right [StateName "implement"])

    it "ends every pending question at a stop" $
        (.pending) <$> replay g (logOf (started :| [ask 1 Design, Forwarded (q 1) TheUser, ask 2 Pick, Stopped halt]))
            `shouldBe` Right []

    it "refuses a ruling where the run's row forwards" $
        replay g (logOf (started :| [ask 1 Design, RuledOn (q 1) proposal])) `shouldBe` Left (NotAllowed (MayNotRule Engineer Design))

    it "refuses a forward of a question the run's row must answer, so no Fact climbs" $
        replay g (logOf (started :| [ask 1 Fact, Forwarded (q 1) TheUser])) `shouldBe` Left (NotAllowed (MustAnswer Engineer Fact))

    it "refuses a ruling on a question retagged Security that names no basis" $
        replay g (logOf (Started (startOf TenXFlow ByUser) :| [ask 1 Design, RetaggedSecurity (q 1), RuledOn (q 1) proposal]))
            `shouldBe` Left (NotAllowed (NoBasis (q 1)))

    it "refuses a forward to another than whoever started the run" $
        replay g (logOf (started :| [ask 1 Design, Forwarded (q 1) parent])) `shouldBe` Left (NotAbove parent)

    it "refuses an answer to a question the run never forwarded" $
        replay g (logOf (started :| [ask 1 Design, Answered (q 1) "yes" TheUser])) `shouldBe` Left (NotForwarded (q 1))

    it "refuses a retag once the question is forwarded" $
        replay g (logOf (started :| [ask 1 Design, Forwarded (q 1) TheUser, RetaggedSecurity (q 1)])) `shouldBe` Left (AlreadyForwarded (q 1))

    it "refuses an event on a question not pending" $
        replay g (logOf (started :| [ask 1 Pick, RuledOn (q 1) proposal, RuledOn (q 1) proposal])) `shouldBe` Left (NotPending (q 1))

    it "refuses asking a pending question again" $
        replay g (logOf (started :| [ask 1 Pick, ask 1 Pick])) `shouldBe` Left (AskedTwice (q 1))

    it "refuses asking a ruled question again, so a retried relay is ruled once" $
        replay g (logOf (started :| [ask 1 Pick, RuledOn (q 1) proposal, ask 1 Pick])) `shouldBe` Left (AskedTwice (q 1))

    it "refuses asking an answered question again" $
        replay g (logOf (started :| [ask 1 Design, Forwarded (q 1) TheUser, Answered (q 1) "yes" TheUser, ask 1 Design]))
            `shouldBe` Left (AskedTwice (q 1))

    it "every_ruling_is_in_show_and_in_the_handback" . hedgehog $ do
        (state, events) <- forAll genAskLog
        let ruled = [(qid, ruling) | RuledOn qid ruling <- events]
            sent = Text.lines (handback "READY ref" state.run state.rulings)
        cover 30 "a ruling" (not (null ruled))
        map (\ruling -> (ruling.qid, ruling.proposal)) state.rulings === ruled
        for_ ruled $ \(qid, ruling) ->
            assert (any (\sentLine -> all (`Text.isInfixOf` sentLine) (qidText qid <> " " : map oneLineText [ruling.answer, ruling.why, ruling.cost])) sent)

    it "no_event_retags_security" . hedgehog $ do
        (state, events) <- forAll genAskLog
        let security = Set.fromList ([asking.question.qid | Asked asking <- events, asking.question.kind == Security] <> [qid | RetaggedSecurity qid <- events])
            kinds =
                [pending.asking.question.kind | pending <- state.pending, Set.member pending.asking.question.qid security]
                    <> [ruling.kind | ruling <- state.rulings, Set.member ruling.qid security]
        cover 5 "a Security question ruled" (any (\ruling -> Set.member ruling.qid security) state.rulings)
        kinds === map (const Security) kinds

    it "every_ask_ends_answered_or_stopped" . hedgehog $ do
        (asker, rungs) <- forAll genChain
        question <- forAll genQuestion
        rung0 <- evalMaybe (NonEmpty.nonEmpty rungs)
        (logs, end) <- climb asker (Question (QId (NonEmpty.head rung0).run 1) question.kind question.text) rungs
        cover 10 "stopped" (end == Halt)
        cover 10 "reached the user" (any (elem TheUser . forwardedTo) logs)
        cover 10 "ruled below the user" (any (\events -> not (null [qid | RuledOn qid _ <- events])) logs)
        for_ (zip rungs logs) $ \(rung, events) -> do
            state <- evalEither (replay g (runLog rung events))
            state.pending === []
  where
    q = QId run
    ask n kind = Asked (Asking (Question (q n) kind (oneLine "a question")) (StateName "implement") Itself)
    proposal = Proposal (oneLine "yes") (oneLine "reversible") (oneLine "an hour") Nothing
    parent = ParentRun (runId "p1")
    forwardedTo events = [to | Forwarded _ to <- events]

halt :: Stop
halt = Stop Blocked "no way on"

-- | A run of this flow under this principal, with no ops.
startOf :: FlowName -> Principal -> Start
startOf flow principal = Start flow "notes" principal Set.empty "a task"

{- | Up to 60 tries at an ask event on a run of either flow, under the user
or a parent, keeping those the fold accepts: the run state and the events.
-}
genAskLog :: Gen (RunState, [Event])
genAskLog = do
    flow <- Gen.enumBounded
    principal <- Gen.element [ByUser, ByRole (runId "p1") "p1/events.jsonl"]
    first <- either (fail . show) pure (replay g (logOf (Started (startOf flow principal) :| [])))
    tries <- Gen.int (Range.linear 0 60)
    go tries first 1 0
  where
    go :: Int -> RunState -> Natural -> Natural -> Gen (RunState, [Event])
    go 0 state _ _ = pure (state, [])
    go k state n fresh = do
        -- Each ask takes a fresh id; the rest name any id so far, or the next.
        let known = QId run <$> Gen.integral (Range.constant 0 fresh)
            above = Gen.element [TheUser, ParentRun (runId "p1")]
            same = fmap (,fresh)
        (event, next) <-
            Gen.frequency
                [ (30, (\kind text -> (Asked (Asking (Question (QId run fresh) kind text) (StateName "implement") Itself), fresh + 1)) <$> Gen.enumBounded <*> genOneLine)
                , (10, same (RetaggedSecurity <$> known))
                , (30, same (RuledOn <$> known <*> genProposal))
                , (30, same (Forwarded <$> known <*> above))
                , (20, same (Answered <$> known <*> genText <*> above))
                , (1, same (pure (Stopped halt)))
                ]
        case append g state (line n event) of
            Right (Appended later) -> fmap (event :) <$> go (k - 1) later (n + 1) next
            Right AlreadyLogged -> go (k - 1) state n fresh
            Left _ -> go (k - 1) state n fresh

-- | A run on the chain a question climbs: its id and how it started.
data Rung = Rung {run :: RunId, start :: Start}
    deriving stock (Show)

-- | How a climb ended for the runs it passed.
data End = Answer Text | Halt
    deriving stock (Eq, Show)

data Try = Rule Proposal | Pass

{- | Who asks, then the runs above it, bottom first: an engineer, a 10x, or an
engineer under a 10x. The user is above the top run.
-}
genChain :: Gen (Asker, [Rung])
genChain =
    (,)
        <$> Gen.element [Itself, Subagent (AgentRole "implementer")]
        <*> Gen.element
            [ [rung "e1" EngineerFlow ByUser]
            , [rung "x1" TenXFlow ByUser]
            , [rung "e1" EngineerFlow (ByRole (runId "x1") "x1/events.jsonl"), rung "x1" TenXFlow ByUser]
            ]
  where
    rung name flow principal = Rung (runId name) (startOf flow principal)

{- | A question climbing the chain, each run reading it as an LLM might and
taking the other choice where the fold refuses its first, or stopping; the
answer comes down to every run below. Each run's log, bottom first.
-}
climb :: Asker -> Question -> [Rung] -> PropertyT IO ([[Event]], End)
climb from question = \case
    [] -> do
        annotate "the user is never asked a Fact"
        question.kind /== Fact
        pure ([], Answer "the user's answer")
    rung : above -> do
        reading <- forAll genReading
        stops <- forAll (Gen.frequency [(9, pure False), (1, pure True)])
        fallback <- forAll genProposal
        let asked = [Asked (Asking question (StateName "implement") from)]
            retag = [RetaggedSecurity question.qid | reading.kind == Security, question.kind /= Security]
            raised = Question question.qid (if null retag then question.kind else Security) question.text
            up = deliver rung.start.principal
            event = \case
                Rule ruling -> RuledOn question.qid ruling
                Pass -> Forwarded question.qid up
            tries = case reading.choice of
                RuleOn ruling -> [Rule ruling, Pass]
                PassOn -> [Pass, Rule fallback {basis = Just (Obvious (oneLine "the user said so"))}]
            taken = asked <> retag
        case (stops, filter (\choice -> isRight (replay g (runLog rung (taken <> [event choice])))) tries) of
            (True, _) -> pure ([asked <> [Stopped halt]], Halt)
            (False, []) -> do
                annotate "the run may neither rule nor forward"
                failure
            (False, Rule ruling : _) -> pure ([taken <> [event (Rule ruling)]], Answer (oneLineText ruling.answer))
            (False, Pass : _) -> do
                (logs, end) <- climb (ChildRun rung.run) raised above
                let closing = case end of
                        Answer answer -> Answered question.qid answer up
                        Halt -> Stopped halt
                pure ((taken <> [event Pass, closing]) : logs, end)

runLog :: Rung -> [Event] -> NonEmpty Envelope
runLog rung events = NonEmpty.zipWith (lineOf rung.run) (0 :| [1 ..]) (Started rung.start :| events)
