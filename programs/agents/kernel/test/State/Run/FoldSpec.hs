module State.Run.FoldSpec (spec) where

import Data.Either (isRight)
import Data.Foldable (for_)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, PropertyT, annotate, assert, cover, evalEither, evalMaybe, failure, forAll, (/==), (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Category.Flow (Flow (..), scopePath)
import State.Category.FlowGen (composes, genFlow, genWalk)
import State.Category.Fuel (Fuel (..))
import State.Category.Graph (Arrow (..), Cap (..), Edge (..), Node (..), OpenGraph (..), Place (..), graph, placeName)
import State.Category.Meter (someMeterName)
import State.Category.Path (ty)
import State.Flow.Engineer (engineer)
import State.Role qualified as Role
import State.Run.Ask (Above (..), Basis (..), Choice (..), Kind (Design, Fact, Pick, Security), Proposal (..), QId (..), Question (..), Reading (..), Refusal (MayNotRule, MustAnswer, NoBasis), deliver, handback, oneLineText, qidText)
import State.Run.Ask qualified as Ask
import State.Run.Event hiding (Merge)
import State.Run.EventGen (genOneLine, genProposal, genQuestion, genReading, genText, hookLine, line, lineOf, logOf, oneLine, outcomeNames, run, runId, started, tasksOf)
import State.Run.Fan qualified as Fan
import State.Run.Fold hiding (Answer (..))
import State.Run.Fold qualified as Fold
import State.Run.RunGen (childOf, commit, g, genAccepted, genAcceptedOn, genKnobs, happyPath, outcomeOf, plainTask, roundTask, securityGraph, securityScope, sha, tenXGraph)
import State.Step.Catalog (outcome, outcomeEvent)
import State.Step.Choice (Outcome (..), choiceNamed, gathering)
import State.Step.Fan (Outcome (..), Sing (Breakdown, Merge), engineers)
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..), Sing (PlanS))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..), Sing (SimplifyPR))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Fold" $ do
    it "names every edge of the engineer and 10x flows by exactly one kind of outcome" $
        -- A fan-out's stays are its children's events; a choice's are its actions' outcomes.
        outcomeNames `shouldBe` Set.fromList [name | flow <- [g, tenXGraph], ((place, name), edge) <- Map.toList flow.edges, edge.arrow /= Stay || isJust (choiceNamed place.name)]

    describe "the 10x's fan-out" $ do
        let tenXLog events = logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| events)
            tenXRun = replay tenXGraph . tenXLog
            -- The writer's path: one more line to the replayed log.
            tenXAppend events event = do
                state <- tenXRun events
                appendTo tenXGraph state (tenXLog events) (line (fromIntegral (length events) + 1) event)
            toEngineers = [Overridden (StateName "breakdown") "the plan is agreed", stepTook (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [])))]
            child = childOf "c1" "t1"
            rePlan = [Overridden (StateName "breakdown") "re-plan", stepTook (BreakdownDone engineers (tasksOf (plainTask "t2" [] :| [])))]
        it "refuses a child's spawn outside the fan-out" $
            tenXRun [Spawned child] `shouldSatisfy` \case
                Left (NoEdge _ _) -> True
                _ -> False
        it "logs a child's spawn and hand-back at the fan-out, staying there" $
            atName <$> tenXRun (toEngineers <> [Spawned child, HandedBack (runId "c1") (AsksUp (QId (runId "c1") 1))])
                `shouldBe` Right (Just (StateName "engineers"))
        it "refuses to write the fan-out's end while a task is unsettled" $
            tenXAppend (toEngineers <> [Spawned child]) (stepTook (FanDone engineers))
                `shouldBe` Left (FanRefused (Fan.Unsettled (TaskId "t1" :| [])))
        it "refuses to write the fan-out's end while a finished task's PR is in CI" $
            tenXAppend (toEngineers <> [Spawned child, HandedBack (runId "c1") (Finished (oneLine "PR #1")), TaskMoved (TaskId "t1") (InCi (Url "pr"))]) (stepTook (FanDone engineers))
                `shouldBe` Left (FanRefused (Fan.Unsettled (TaskId "t1" :| [])))
        it "replays a v4 log's fan-out end with a finished task's PR in CI" $
            atName <$> tenXRun (toEngineers <> [Spawned child, HandedBack (runId "c1") (Finished (oneLine "PR #1")), TaskMoved (TaskId "t1") (InCi (Url "pr")), stepTook (FanDone engineers)])
                `shouldBe` Right (Just (StateName "merge"))
        it "leaves the fan-out for the merge once every task is settled" $
            atName <$> tenXRun (toEngineers <> [Spawned child, HandedBack (runId "c1") (Finished (oneLine "PR #1")), stepTook (FanDone engineers)])
                `shouldBe` Right (Just (StateName "merge"))
        it "refuses a task the breakdown lacks" $
            tenXRun (toEngineers <> [Held (TaskId "t9") (Url "u")]) `shouldBe` Left (FanRefused (Fan.UnknownTask (TaskId "t9")))
        it "takes a stop at the merge once every task is parked" $ do
            let allParked = Stop Blocked "all tasks parked"
            (.stopped) <$> tenXRun (toEngineers <> [TaskMoved (TaskId "t1") (Parked "out of scope" Nothing), stepTook (FanDone engineers), Stopped allParked])
                `shouldBe` Right (Just allParked)
        it "refuses a new breakdown while a child is at work" $
            tenXRun (toEngineers <> [Spawned child] <> rePlan) `shouldBe` Left (FanRefused (Fan.Busy (TaskId "t1" :| [])))
        it "starts a fresh fan-out at a new breakdown once every child handed back" $
            fmap (.id) . (.tasks) . currentFan <$> tenXRun (toEngineers <> [Spawned child, HandedBack (runId "c1") (Finished (oneLine "PR #1"))] <> rePlan)
                `shouldBe` Right [TaskId "t2"]
        it "adds a task mid-run, one the merge then awaits" $ do
            let fix = plainTask "fix" []
                withFix = toEngineers <> [TaskAdded fix]
            fmap (.id) . (.tasks) . currentFan <$> tenXRun withFix `shouldBe` Right [TaskId "t1", TaskId "fix"]
            tenXRun (withFix <> [TaskMoved (TaskId "t1") (Merged (Url "pr")), TaskMoved (TaskId "fix") (InReview (Url "fix-pr")), stepTook (FanDone engineers), stepTook (MergeDone engineers (Url "pr"))])
                `shouldBe` Left (FanRefused (Fan.Unmerged (TaskId "fix" :| [])))
        it "refuses an added task under an id the fan-out has" $
            tenXRun (toEngineers <> [TaskAdded (plainTask "t1" [])]) `shouldBe` Left (FanRefused (Fan.TaskExists (TaskId "t1")))
        it "frees every agent at a restart, so its child waits on the run" $
            fmap (.child.run) . Fan.waiting . currentFan <$> tenXRun (toEngineers <> [Spawned child, Restarted]) `shouldBe` Right [runId "c1"]

    describe "a lead's workers" $ do
        let fixer = AgentRole "fixer"
            atWork events = map (\worker -> (worker.agent, worker.spawnedAt)) . (.live) <$> replay g (logOf (Started start0 :| events))
            start0 = startOf EngineerFlow (ByUser OwnPr)
            spawn role agent = WorkerSpawned role (AgentId agent)
        it "holds each worker spawned, by the seq of its spawn, until the one of its id returns" $
            atWork [spawn fixer "a1", spawn fixer "a2", WorkerReturned fixer (Just (AgentId "a2"))] `shouldBe` Right [(AgentId "a1", 1)]
        it "closes the oldest of the role when the return names no id" $
            atWork [spawn fixer "a1", spawn (AgentRole "implementer") "b1", spawn fixer "a2", WorkerReturned fixer Nothing] `shouldBe` Right [(AgentId "b1", 2), (AgentId "a2", 3)]
        it "changes nothing at the return of a worker not at work" $
            atWork [spawn fixer "a1", WorkerReturned fixer (Just (AgentId "a9")), WorkerReturned (AgentRole "implementer") Nothing] `shouldBe` Right [(AgentId "a1", 1)]
        it "forgets every worker at a restart" $
            atWork [spawn fixer "a1", Restarted] `shouldBe` Right []
        it "forgets a worker whose spawn is voided, so its lead may hand back" $
            atWork [spawn fixer "a1", spawn fixer "a2", Voided 1 "lost at a crash"] `shouldBe` Right [(AgentId "a2", 2)]
        it "a_worker_returned_by_its_id_is_at_work_no_more" . hedgehog $ do
            -- A hook logs each worker's spawn once: ids are distinct.
            ids <- forAll (Gen.shuffle =<< Gen.subsequence ["a1", "a2", "a3", "a4", "a5"])
            back <- forAll (Gen.shuffle =<< Gen.subsequence ids)
            let left = map fst <$> atWork (map (spawn fixer) ids <> [WorkerReturned fixer (Just (AgentId agent)) | agent <- back])
            fmap (filter (`elem` map AgentId back)) left === Right []

    describe "two fan-outs in one flow" $ do
        let twoFansRun events = replay twoFans (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| events))
            t1 = TaskId "t1"
            firstDone =
                [ stepTook (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [])))
                , Spawned (childOf "c1" "t1")
                , HandedBack (runId "c1") (Finished (oneLine "PR #1"))
                , stepTook (FanDone engineers)
                ]
            bothDone = firstDone <> [tookIn (scopePath "second") (FanDone engineers)]
        it "keeps the first fan-out's tasks out of the second" $
            twoFansRun (firstDone <> [Spawned (childOf "c2" "t1")]) `shouldBe` Left (FanRefused (Fan.UnknownTask t1))
        it "leaves the second, empty fan-out by its own done record" $
            atName <$> twoFansRun bothDone `shouldBe` Right (Just (StateName "merge"))
        it "refuses the first fan-out's merge while its task is unmerged" $
            twoFansRun (bothDone <> [stepTook (MergeDone engineers (Url "pr"))]) `shouldBe` Left (FanRefused (Fan.Unmerged (t1 :| [])))
        it "credits a task's move at a merge to that merge's fan-out" $
            (.at) <$> twoFansRun (bothDone <> [TaskMoved t1 (Merged (Url "pr")), stepTook (MergeDone engineers (Url "pr"))]) `shouldBe` Right Exit
        it "refuses a task's move off every fan-out's state" $
            twoFansRun (bothDone <> [TaskMoved t1 (Merged (Url "pr")), stepTook (MergeDone engineers (Url "pr")), TaskMoved t1 (Merged (Url "pr"))]) `shouldBe` Left NotAtFan

    describe "a flow with a scoped copy" $ do
        let securityRun events = replay securityGraph (logOf (started :| events))
            toSecurity = [stepTook (ReviewRows sha), stepTook (PickFinal (Picks Set.empty Map.empty))]
        it "takes the copy's outcome in its scope, to the copy's next state" $
            atName <$> securityRun (toSecurity <> [tookIn securityScope (ReviewRows sha)]) `shouldBe` Right (Just (StateName "security/pick"))
        it "refuses the copy's outcome named bare: it is the other review's" $
            securityRun (toSecurity <> [stepTook (ReviewRows sha)]) `shouldSatisfy` \case
                Left (NoEdge _ _) -> True
                _ -> False

    describe "two scoped copies of one fan-out" $ do
        let copiesRun events = replay scopedFans (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| events))
            inA = tookIn (scopePath "a")
            settled =
                [ inA (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [])))
                , Spawned (childOf "c1" "t1")
                , HandedBack (runId "c1") (Finished (oneLine "PR #1"))
                , inA (FanDone engineers)
                , TaskMoved (TaskId "t1") (Merged (Url "pr"))
                , inA (MergeNextRound engineers)
                , stepTook (PlanDone "plan.md")
                ]
        it "starts the second copy with none of the first's tasks" $
            (\state -> (atName state, map (.id) (currentFan state).tasks)) <$> copiesRun settled
                `shouldBe` Right (Just (StateName "b/breakdown"), [])

    it "runs the engineer flow's happy path to its end" $
        (.at) <$> replay g (logOf (started :| map (Took mempty) happyPath)) `shouldBe` Right Out

    it "every_accepted_log_is_a_path" . hedgehog $ do
        events <- forAll genCandidate
        case replay g (logOf (started :| events)) of
            Left _ -> cover 10 "refused" True
            Right state -> do
                cover 20 "accepted" True
                cover 5 "reached the end" (state.at == Out)
                path <- evalMaybe (ty g [tookEvent scope took | Took scope took <- events])
                assert (composes path)

    it "every_accepted_log_of_a_scoped_flow_is_a_path" . hedgehog $ do
        f <- forAll (Gen.filter (isRight . graph) genFlow)
        flow <- evalEither (graph f)
        events <- forAll (genAcceptedOn flow)
        cover 10 "a step's outcome inside a scope" (or [scope /= mempty | Took scope _ <- events])
        path <- evalMaybe (ty flow [tookEvent scope took | Took scope took <- events])
        assert (composes path)

    it "never_spends_past_a_cap" . hedgehog $ do
        events <- forAll genAccepted
        states <- traverse (evalEither . replay g . logOf) (NonEmpty.toList (NonEmpty.inits1 (started :| events)))
        let held = [budget | state <- states, budget <- Map.elems (budgets g state)]
        cover 1 "a used-up budget" (any usedUp held)
        for_ held $ \budget -> assert (all (budget.ledger.spent <=) budget.allows)

    -- At the pick, before the fixer runs, so the run can still take the loop's exit.
    it "refuses a re-review past Low's one at the loop pick" $
        replay g (logOf (started :| FuelSet Low : toReview <> reviewRounds [[], []]))
            `shouldSatisfy` outOf "Re-reviews" 1

    it "takes the loop's exit at Low's used-up pick" $
        atName <$> replay g (logOf (started :| FuelSet Low : toReview <> reviewRounds [[]] <> [stepTook (FixDone commit), stepTook (ReReviewRows sha), stepTook (PickFinal (Picks Set.empty Map.empty))]))
            `shouldBe` Right (Just (StateName "describe"))

    -- An Unverified requirement is a verdict, never a row (#440).
    it "takes a final pick with no row and an Unverified verdict to describe" $
        atName <$> replay g (logOf (started :| toReview <> [stepTook (ReviewRows sha), stepTook (PickFinal (Picks Set.empty (Map.singleton (Requirement "R1") Unverified)))]))
            `shouldBe` Right (Just (StateName "describe"))

    it "stuck_after_two_same_rounds" . hedgehog $ do
        -- Up to Max's 5 re-reviews, each a pick of the loop.
        rows <- forAll (Gen.list (Range.linear 1 5) (Gen.subsequence ["A", "B", "C"]))
        state <- evalEither (replay g (logOf (started :| FuelSet Max : toReview <> reviewRounds rows)))
        let expected = case reverse rows of
                current : previous : _ -> Set.map (Row . Label) (Set.fromList current `Set.intersection` Set.fromList previous)
                _ -> Set.empty
        cover 10 "stuck" (not (Set.null expected))
        stuck state === [Stuck "fix" expected | not (Set.null expected)]

    it "is not stuck on rows alternating A, B, A, B: only rounds in a row count" $
        stuck <$> replay g (logOf (started :| FuelSet Max : toReview <> reviewRounds [["A"], ["B"], ["A"], ["B"]]))
            `shouldBe` Right []

    it "is stuck on one failing check in two CI rounds in a row" $ do
        let red = stepTook (AwaitCiRed sha (Check "lint" :| []))
        stuck <$> replay g (logOf (started :| toCi <> [red, stepTook (FixPrDone sha), red]))
            `shouldBe` Right [Stuck "ci" (Set.singleton (Failing (Check "lint")))]

    it "forgets a loop's rounds once the run leaves it" $
        stuck <$> replay g (logOf (started :| FuelSet Max : toReview <> reviewRounds [["A"], ["A"]] <> [stepTook (FixDone commit), stepTook (ReReviewClean sha)]))
            `shouldBe` Right []

    it "restarts gathering in each round of the plan loop" $ do
        let gather = [outcome ResearchSpawned, outcome ResearchHandedBack]
            gathered = concat (replicate 4 gather) <> [outcome (Enough gathering), outcome (PlanDone "p"), outcome SimplifyPlanDone, outcome ConfirmAdjusted] <> gather
        Map.map length . (.rounds) <$> replay g (logOf (started :| map (Took mempty) gathered))
            `shouldBe` Right (Map.fromList [("gather", 1), ("plan", 2)])

    gatherBudgets
    tenXRounds

    it "append_is_idempotent_by_id" . hedgehog $ do
        events <- forAll genAccepted
        let logged = logOf (started :| events)
        state <- evalEither (replay g logged)
        again <- forAll (Gen.element (NonEmpty.toList logged))
        append g state again === Right AlreadyLogged

    it "logs a hook record fired twice once" $ do
        let hook n = hookLine "ab12" n (stepTook ResearchSpawned)
        (.at) <$> replay g (line 0 started :| [hook 1, hook 2]) `shouldBe` (.at) <$> replay g (line 0 started :| [hook 1])

    describe "a void" $ do
        it "a_void_replays_as_the_line_never_logged" . hedgehog $ do
            events <- forAll genAccepted
            let logged = logOf (started :| events)
                lastSeq = fromIntegral (length events)
            target <- forAll (Gen.integral (Range.linear 0 lastSeq))
            state <- evalEither (replay g logged)
            let without = maybe (Left NotStarted) (replay g) (NonEmpty.nonEmpty (NonEmpty.filter ((/= target) . (.seq)) logged))
                voided = appendTo g state logged (line (lastSeq + 1) (Voided target "logged in error"))
            cover 5 "the log without it replays" (isRight without)
            cover 5 "the log without it does not" (not (isRight without))
            (unseenIn <$> voided) === either (Left . VoidBreaks target) (Right . Appended . unseen) without
        it "refuses a seq no line the run replays has: none, a voided one, a void" $ do
            let logged = line 0 started :| [line 1 (FuelSet Max), line 2 (Voided 1 "set by mistake")]
            state <- either (fail . show) pure (replay g logged)
            [appendTo g state logged (line 3 (Voided n "why")) | n <- [9, 1, 2]] `shouldBe` map (Left . NotVoidable) [9, 1, 2]
        it "keeps a voided hook line's id, so the hook fired again logs nothing" $ do
            let hooked = hookLine "ab12" 1 (stepTook ResearchSpawned)
                logged = line 0 started :| [hooked, line 2 (Voided 1 "fired at the wrong run")]
            state <- either (fail . show) pure (replay g logged)
            (Right state.at, append g state hooked {seq = 3}) `shouldBe` ((.at) <$> replay g (line 0 started :| []), Right AlreadyLogged)

    it "state_is_a_fold" . hedgehog $ do
        events <- forAll genAccepted
        split <- forAll (Gen.int (Range.linear 1 (length events + 1)))
        let (before, after) = NonEmpty.splitAt split (logOf (started :| events))
        firstPart <- evalMaybe (NonEmpty.nonEmpty before)
        (replay g firstPart >>= \state -> fold g state after) === replay g (logOf (started :| events))

    it "refuses a log whose first line is not started" $
        replay g (logOf (stepTook ResearchSpawned :| [])) `shouldBe` Left NotStarted

    it "refuses an event with no edge where the run is" $
        replay g (logOf (started :| [stepTook (ReviewClean sha)])) `shouldBe` Left (NoEdge (At research) (outcomeEvent (outcome (ReviewClean sha))))

    it "refuses a second Fuel" $
        replay g (logOf (started :| [FuelSet Max, FuelSet Low])) `shouldBe` Left (FuelSetOnce Max)

    it "takes the same Fuel again" $
        fuelOf <$> replay g (logOf (started :| [FuelSet Max, FuelSet Max])) `shouldBe` Right Max

    it "takes no event after a stop" $
        replay g (logOf (started :| [Stopped stop, stepTook ResearchSpawned])) `shouldBe` Left (AfterStop stop)

    it "logs a refusal after a stop" $
        (.refused) <$> replay g (logOf (started :| [Stopped stop, Refused note])) `shouldBe` Right (Just note)

    it "warns of a refusal until the next event" $
        (.refused) <$> replay g (logOf (started :| [Refused note, stepTook ResearchSpawned])) `shouldBe` Right Nothing

    it "refuses a line of another run" $
        replay g (line 0 started :| [ofRun (runId "other") (line 1 (stepTook ResearchSpawned))]) `shouldBe` Left (OtherRun (runId "other"))

    it "overrides to a named state" $
        atName <$> replay g (logOf (started :| [Overridden (StateName "review") "why"])) `shouldBe` Right (Just (StateName "review"))

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

-- | From the start to the first review.
toReview :: [Event]
toReview = map (Took mempty) (take 9 happyPath)

-- | From the start to the first CI result.
toCi :: [Event]
toCi = map (Took mempty) (take 9 happyPath <> [outcome (ReviewClean sha), outcome (DescribeDone sha), outcome (SimplifyPrDone sha)])

-- | Fix rounds that pick these rows, as 'pickRounds'.
reviewRounds :: [[Text]] -> [Event]
reviewRounds = pickRounds . map (\rows -> Picks (Set.fromList (map Label rows)) Map.empty)

-- | A review with rows, then a round per pick, fixed and re-reviewed before the next; the last ends at its pick.
pickRounds :: [Picks] -> [Event]
pickRounds = \case
    [] -> []
    picks -> stepTook (ReviewRows sha) : intercalate [stepTook (FixDone commit), stepTook (ReReviewRows sha)] [[stepTook (PickLoop p)] | p <- picks]

-- | Refused as a spend past the named meter's cap, which allows this many at the run's Fuel.
outOf :: Text -> Natural -> Either Fold.Refusal a -> Bool
outOf meter most = \case
    Left (OutOfBudget cap n) -> someMeterName cap.meter == meter && n == most
    _ -> False

-- | Any Fuel, then a walk to the end, sometimes with an event from anywhere in the flow.
genCandidate :: Gen [Event]
genCandidate = do
    knobs <- genKnobs
    walk <- genWalk g
    noise <- Gen.element (Set.toList outcomeNames)
    at <- Gen.int (Range.linear 0 (length walk))
    names <- Gen.element [walk, take at walk <> [noise] <> drop at walk]
    outcomes <- traverse outcomeOf names
    pure (knobs <> map (Took mempty) outcomes)

{- | The gather's choice: researchers spawned in the background and
questions asked, as the agent picks; neither budget spends the other,
@extend@ grants both again, each entry into the choice starts both afresh,
and @enough@ waits for every researcher to hand back.
-}
gatherBudgets :: Spec
gatherBudgets = describe "the gather's choice" $ do
    it "asks 20 questions at Balanced, spending no researcher" $
        replay g (logOf (started :| spawns 5 <> asks 1 20)) `shouldSatisfy` isRight

    it "refuses the question past Balanced's 30" $
        replay g (logOf (started :| asks 1 31)) `shouldSatisfy` outOf "Interview questions" 30

    it "takes a Stuck question past the questions, as asking whether to go on" $
        replay g (logOf (started :| asks 1 30 <> [askAt 31 Ask.Stuck])) `shouldSatisfy` isRight

    it "counts no question asked off the gather" $
        replay g (logOf (started :| enough : asks 1 31)) `shouldSatisfy` isRight

    for_ [(Low, 1), (Balanced, 5)] $ \(fuel, allowed) ->
        it ("spawns " <> show allowed <> " researchers at " <> show fuel <> " and refuses the next") $ do
            replay g (logOf (started :| FuelSet fuel : spawns allowed)) `shouldSatisfy` isRight
            replay g (logOf (started :| FuelSet fuel : spawns (allowed + 1))) `shouldSatisfy` outOf "Researchers" (fromIntegral allowed)

    it "spawns a researcher per group of the plan at Max, as many as the agent counts" $
        replay g (logOf (started :| FuelSet Max : spawns 12)) `shouldSatisfy` isRight

    it "takes hand-backs in any order between questions, then leaves by enough" $
        atName <$> replay g (logOf (started :| spawns 2 <> asks 1 2 <> [handedBack] <> spawns 1 <> asks 3 1 <> [handedBack, handedBack, enough]))
            `shouldBe` Right (Just (StateName "plan"))

    it "refuses enough while a researcher is open" $
        replay g (logOf (started :| spawns 2 <> [handedBack, enough])) `shouldBe` Left (StillOpen 1)

    it "refuses a hand-back with no researcher open" $
        replay g (logOf (started :| spawns 1 <> [handedBack, handedBack])) `shouldBe` Left (NoneOpen (StateName "research"))

    it "grants another 5 researchers and 30 questions after extend, keeping the open ones" $ do
        let extended = spent <> [Extended "the user goes on"] <> asks 31 30 <> spawns 5
        replay g (logOf (started :| extended <> [askAt 61 Fact])) `shouldSatisfy` outOf "Interview questions" 30
        replay g (logOf (started :| extended <> spawns 1)) `shouldSatisfy` outOf "Researchers" 5
        replay g (logOf (started :| extended <> replicate 9 handedBack <> [enough])) `shouldBe` Left (StillOpen 1)
        replay g (logOf (started :| extended <> replicate 10 handedBack <> [enough])) `shouldSatisfy` isRight

    it "starts both budgets afresh when the run gathers again after an adjusted plan" $ do
        let adjusted = spent <> replicate 5 handedBack <> [enough, stepTook (PlanDone "p"), stepTook SimplifyPlanDone, stepTook ConfirmAdjusted]
        replay g (logOf (started :| adjusted <> asks 31 30 <> spawns 5)) `shouldSatisfy` isRight

    it "refuses extend outside the gather" $
        replay g (logOf (started :| map (Took mempty) (take 7 happyPath) <> [Extended "why"])) `shouldBe` Left NothingToExtend
  where
    spawns n = replicate n (stepTook ResearchSpawned)
    handedBack = stepTook ResearchHandedBack
    enough = stepTook (Enough gathering)
    -- Balanced's researchers and questions, all used.
    spent = spawns 5 <> asks 1 30
    asks from n = [askAt i Fact | i <- [from .. from + n - 1]]
    askAt n kind = Asked (Asking (Question (QId run n) kind (oneLine "a question")) (StateName "gather") Itself)

{- | The 10x's rounds: a round task keeps its PR open, the merge ends the run
or loops back to gather for the next round, with fresh budgets.
-}
tenXRounds :: Spec
tenXRounds = describe "the 10x's rounds" $ do
    for_ [minBound .. maxBound] $ \fuel ->
        it ("lets a round on an existing PR skip ready at " <> show fuel) $
            (.at) <$> engineerRun (ByRole parent (RoundOn pr) ChildConfirms) fuel `shouldBe` Right Out

    for_ [Balanced, Max] $ \fuel ->
        it ("refuses an ordinary task's skip of ready at " <> show fuel) $
            engineerRun (ByRole parent OwnPr ChildConfirms) fuel `shouldBe` Left (NotSkippable "ready")

    it "ends a run whose tasks merged by merge done" $
        (.at) <$> tenXRun (settled (plainTask "t1" []) (Merged pr) <> [stepTook (MergeDone engineers pr)]) `shouldBe` Right Out

    it "ends a run whose tasks are only kept by merge done" $
        (.at) <$> tenXRun (settled onPr (Kept pr) <> [stepTook (MergeDone engineers pr)]) `shouldBe` Right Out

    it "goes back to gather at a fresh round by next_round" $
        fmap (\state -> (atName state, Map.map length state.rounds)) (tenXRun round1)
            `shouldBe` Right (Just (StateName "gather"), Map.fromList [("gather", 1), ("plan", 1), ("round", 2)])

    it "starts both gather budgets afresh in the next round" $ do
        let spentAgain = round1 <> spent 31
        tenXRun spentAgain `shouldSatisfy` isRight
        tenXRun (spentAgain <> [askAt 61]) `shouldSatisfy` outOf "Interview questions" 30

    it "respawns the same task in the next round" $
        atName <$> tenXRun (round1 <> agreed <> [Spawned (childOf "c2" "t1")]) `shouldBe` Right (Just (StateName "engineers"))

    it "refuses to keep an ordinary task's PR" $
        tenXRun (toEngineers (plainTask "t1" []) <> [TaskMoved t1 (Kept pr)]) `shouldBe` Left (FanRefused (Fan.NotARound t1))

    it "refuses to keep a PR other than the round's own" $
        tenXRun (toEngineers onPr <> [TaskMoved t1 (Kept (Url "https://pr/2"))]) `shouldBe` Left (FanRefused (Fan.NotItsRound t1 pr))

    it "goes back to the fan-out for a task added at the merge, and spawns it" $ do
        let added = settled (plainTask "t1" []) (Merged pr) <> [TaskAdded (plainTask "fix" [])]
        atName <$> tenXRun added `shouldBe` Right (Just (StateName "engineers"))
        atName <$> tenXRun (added <> [Spawned (childOf "c2" "fix")]) `shouldBe` Right (Just (StateName "engineers"))
  where
    pr = Url "https://pr/1"
    t1 = TaskId "t1"
    parent = Parent (runId "p1") "p1/events.jsonl" t1
    engineerRun principal fuel = replay g (logOf (Started (startOf EngineerFlow principal) :| FuelSet fuel : map (Took mempty) (init happyPath) <> [stepTook (ReadySkipped pr)]))
    tenXRun events = replay tenXGraph (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| events))
    agreed = [stepTook ResearchSpawned, stepTook ResearchHandedBack, stepTook (Enough gathering), stepTook (PlanDone "p"), stepTook SimplifyPlanDone, stepTook ConfirmConfirmed, stepTook (BreakdownDone engineers (tasksOf (onPr :| [])))]
    onPr = roundTask "t1" "https://pr/1"
    toEngineers task = [Overridden (StateName "breakdown") "the plan is agreed", stepTook (BreakdownDone engineers (tasksOf (task :| [])))]
    settled task moved = toEngineers task <> [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "READY")), TaskMoved t1 moved, stepTook (FanDone engineers)]
    -- The first round spends Balanced's 5 researchers and 30 questions, then loops.
    round1 = spent 1 <> drop 1 agreed <> [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "READY")), TaskMoved t1 (Kept pr), stepTook (FanDone engineers), stepTook (MergeNextRound engineers)]
    -- Balanced's 5 researchers, one handed back before the round ends, and 30 questions.
    spent from = replicate 5 (stepTook ResearchSpawned) <> replicate 4 (stepTook ResearchHandedBack) <> map askAt [from .. from + 29]
    askAt n = Asked (Asking (Question (QId run n) Fact (oneLine "a question")) (StateName "gather") Itself)

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
        replay g (logOf (started :| [ask 1 Design, RuledOn (q 1) proposal])) `shouldBe` Left (NotAllowed (MayNotRule Role.Lead Design))

    it "refuses a forward of a question the run's row must answer, so no Fact climbs" $
        replay g (logOf (started :| [ask 1 Fact, Forwarded (q 1) TheUser])) `shouldBe` Left (NotAllowed (MustAnswer Role.Lead Fact))

    it "refuses a ruling on a question retagged Security that names no basis" $
        replay g (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| [ask 1 Design, RetaggedSecurity (q 1), RuledOn (q 1) proposal]))
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

    it "takes an answer it holds again as no news, and refuses another" $ do
        let answered = [ask 1 Design, Forwarded (q 1) TheUser, Answered (q 1) "yes" TheUser]
        map (\more -> (.answers) <$> replay g (logOf (started :| answered <> more))) [[], [Answered (q 1) "yes" TheUser]]
            `shouldBe` replicate 2 (Right [Fold.Answer (Question (q 1) Design (oneLine "a question")) "yes"])
        replay g (logOf (started :| answered <> [Answered (q 1) "no" TheUser])) `shouldBe` Left (AnsweredOtherwise (q 1) "yes")

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
            -- An answer that came down, given again, is no news; another is refused.
            for_ [(qid, answer, by) | Answered qid answer by <- events] $ \(qid, answer, by) -> do
                again <- evalEither (replay g (runLog rung (events <> [Answered qid answer by])))
                (again.answers, again.pending) === (state.answers, state.pending)
                replay g (runLog rung (events <> [Answered qid (answer <> " or not") by])) === Left (AnsweredOtherwise qid answer)
  where
    q = QId run
    ask n kind = Asked (Asking (Question (q n) kind (oneLine "a question")) (StateName "implement") Itself)
    proposal = Proposal (oneLine "yes") (oneLine "reversible") (oneLine "an hour") Nothing
    parent = ParentRun (runId "p1")
    forwardedTo events = [to | Forwarded _ to <- events]

halt :: Stop
halt = Stop Blocked "no way on"

{- | One fan-out twice, inside scopes @a@ and @b@: each copy is its own
fan-out, with its own tasks and children.
-}
scopedFans :: OpenGraph
scopedFans = either (error . show) id (graph (Scope "a" fanned :> Do PlanS :> Scope "b" fanned))
  where
    fanned = Do (Breakdown engineers) :> Par engineers engineer :> Do (Merge engineers)

{- | A flow with two fan-outs, the second a scoped copy that runs on the
first's PRs. No step goes from a PR back to a plan, so the second has no
breakdown of its own.
-}
twoFans :: OpenGraph
twoFans = either (error . show) id (graph (Do (Breakdown engineers) :> Par engineers engineer :> Scope "second" (Par engineers (Do SimplifyPR)) :> Do (Merge engineers)))

-- | The state a run is at, if it is at one.
atName :: RunState -> Maybe StateName
atName state = case state.at of
    At place -> Just (placeName place)
    Out -> Nothing
    Exit -> Nothing

-- | A run of this flow under this principal, with no ops.
startOf :: FlowName -> Principal -> Start
startOf flow principal = Start flow "notes" principal Set.empty

{- | Up to 60 tries at an ask event on a run of either flow, under the user
or a parent, keeping those the fold accepts: the run state and the events.
-}
genAskLog :: Gen (RunState, [Event])
genAskLog = do
    flow <- Gen.enumBounded
    principal <- Gen.element [ByUser OwnPr, ByRole (Parent (runId "p1") "p1/events.jsonl" (TaskId "t1")) OwnPr ChildConfirms]
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
                , (40, same (RuledOn <$> known <*> genProposal))
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
            [ [rung "e1" EngineerFlow (ByUser OwnPr)]
            , [rung "x1" TenXFlow (ByUser OwnPr)]
            , [rung "e1" EngineerFlow (ByRole (Parent (runId "x1") "x1/events.jsonl" (TaskId "t1")) OwnPr ChildConfirms), rung "x1" TenXFlow (ByUser OwnPr)]
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

-- | The state less the ids it has seen, which a void keeps.
unseen :: RunState -> RunState
unseen state = state {seen = Set.empty}

unseenIn :: Append -> Append
unseenIn = \case
    Appended state -> Appended (unseen state)
    AlreadyLogged -> AlreadyLogged
