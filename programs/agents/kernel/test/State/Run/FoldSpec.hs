module State.Run.FoldSpec (spec) where

import Data.Either (isRight)
import Data.Foldable (for_)
import Data.List (inits, intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, PropertyT, annotate, annotateShow, assert, cover, discard, evalEither, evalMaybe, failure, forAll, success, (/==), (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Category.Effect (Handler (FocusHere))
import State.Category.Flow (Flow (..), Group (..), scopePath, unqualify)
import State.Category.FlowGen (AnyFlow (..), builds, composes, genFlow, genWalk, threeWay, threeWayGraph, threeWayPick)
import State.Category.Fuel (Fuel (..))
import State.Category.Graph (Arrow (..), Cap (..), Edge (..), Node (..), OpenGraph (..), Place (..), graph, placeName, places)
import State.Category.Graph qualified as Graph
import State.Category.Meter (someMeterName)
import State.Category.Path (ty, unrecorded)
import State.Category.Step (EventName (..), OutcomeName (..), StepSet (stepName), stateNameText)
import State.Flow.Drawn (drawnOutcomes, fuelTakes)
import State.Flow.Engineer (engineer)
import State.Flow.Library qualified as Library
import State.Flow.TenX (tenX)
import State.Role qualified as Role
import State.Run.Ask (Above (..), Basis (..), Decision (..), Kind (Design, Fact, Pick, Security), Proposal (..), QId (..), Question (..), Reading (..), Refusal (MayNotRule, MustAnswer, NoBasis), deliver, handback, oneLineText, qidText)
import State.Run.Ask qualified as Ask
import State.Run.Event hiding (Merge)
import State.Run.EventGen (fuelSet, genOneLine, genProposal, genQuestion, genReading, genText, hookLine, line, lineOf, logOf, oneLine, outcomeNames, run, runId, started, tasksOf)
import State.Run.Fan qualified as Fan
import State.Run.Fold hiding (Answer (..))
import State.Run.Fold qualified as Fold
import State.Run.RunGen (architectGraph, chiefGraph, childOf, commit, designDiscussed, enoughIn, g, genAccepted, genAcceptedOn, happyPath, outcomeOf, pickOf, plainTask, problemUnderstood, researchedIn, roundTask, runOf, scopedIn, securityGraph, securityScope, sha, spawnedIn, tenXAt, tenXGraph, ticketUrl, within)
import State.Step.Catalog (AnyOutcome (..), Layer (PickLayer), flowOutcomes, outcome, outcomeEvent, termSteps)
import State.Step.Fan (Outcome (..), Sing (Breakdown, Merge), engineers)
import State.Step.Fuel (Outcome (LevelSet), Sing (Fuel))
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..), Sing (PlanS))
import State.Step.Request (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..), Sing (SimplifyPR))
import State.Step.Ticket (Outcome (..), Sing (ConfirmDesign))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Fold" $ do
    it "names every edge of the engineer, 10x, architect and chief flows by exactly one kind of outcome" $
        -- A fan-out's stays are its children's events. A scope's are named bare. An await goes on
        -- by no event, and a researcher hands back by no edge: wherever the run is.
        Set.delete (outcomeEvent (outcome ResearchHandedBack)) outcomeNames
            `shouldBe` Set.fromList [EventName (StateName (snd (unqualify (stateNameText name.step)))) name.outcome | flow <- [g, tenXGraph, architectGraph, chiefGraph], ((place, name), edge) <- Map.toList flow.edges, edge.arrow /= Stay, isNothing (unrecorded flow place)]

    describe "the 10x's fan-out" $ do
        let tenXLog events = logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| events)
            tenXRun = replay tenXGraph . tenXLog
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
        it "waits at the engineers' await while a task is unsettled" $
            atName <$> tenXRun (toEngineers <> [Spawned child]) `shouldBe` Right (Just (StateName "engineers"))
        it "waits at the engineers' await while a task's PR is in CI" $
            atName <$> tenXRun (toEngineers <> [Spawned child, TaskMoved (TaskId "t1") (InCi (Url "pr")), HandedBack (runId "c1") (Finished (oneLine "PR #1"))])
                `shouldBe` Right (Just (StateName "engineers"))
        it "goes on to the merge by itself once every task is settled" $
            atName <$> tenXRun (toEngineers <> [Spawned child, HandedBack (runId "c1") (Finished (oneLine "PR #1"))])
                `shouldBe` Right (Just (StateName "merge"))
        it "refuses a task the breakdown lacks" $
            tenXRun (toEngineers <> [Held (TaskId "t9") (Url "u")]) `shouldBe` Left (FanRefused (Fan.UnknownTask (TaskId "t9")))
        it "takes a stop at the merge once every task is parked" $ do
            let allParked = Stop Blocked "all tasks parked"
            (.stopped) <$> tenXRun (toEngineers <> [TaskMoved (TaskId "t1") (Parked "out of scope" Nothing), Stopped allParked])
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
            tenXRun (withFix <> [TaskMoved (TaskId "t1") (Merged (Url "pr")), TaskMoved (TaskId "fix") (InReview (Url "fix-pr")), stepTook (MergeDone engineers (Url "pr"))])
                `shouldBe` Left (FanRefused (Fan.Unmerged (TaskId "fix" :| [])))
        it "refuses an added task under an id the fan-out has" $
            tenXRun (toEngineers <> [TaskAdded (plainTask "t1" [])]) `shouldBe` Left (FanRefused (Fan.TaskExists (TaskId "t1")))
        it "frees every agent at a restart, so its child waits on the run" $
            fmap (.child.run) . Fan.waiting . currentFan <$> tenXRun (toEngineers <> [Spawned child, Restarted]) `shouldBe` Right [runId "c1"]

    describe "a lead's workers" $ do
        let fixer = AgentRole "fixer"
            atWork events = map (\worker -> (worker.agent, worker.spawnedAt)) . (.workers) <$> replay g (logOf (Started start0 :| events))
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
                ]
            bothDone = firstDone
        it "passes the second, empty fan-out by itself" $
            atName <$> twoFansRun bothDone `shouldBe` Right (Just (StateName "merge"))
        it "refuses the first fan-out's merge while its task is unmerged" $
            twoFansRun (bothDone <> [stepTook (MergeDone engineers (Url "pr"))]) `shouldBe` Left (FanRefused (Fan.Unmerged (t1 :| [])))
        it "credits a task's move at a merge to that merge's fan-out" $
            (.at) <$> twoFansRun (bothDone <> [TaskMoved t1 (Merged (Url "pr")), stepTook (MergeDone engineers (Url "pr"))]) `shouldBe` Right Graph.Exit
        it "refuses a task's move off every fan-out's state" $
            twoFansRun (bothDone <> [TaskMoved t1 (Merged (Url "pr")), stepTook (MergeDone engineers (Url "pr")), TaskMoved t1 (Merged (Url "pr"))]) `shouldBe` Left NotAtFan

    describe "a flow with a scoped copy" $ do
        let securityRun events = replay securityGraph (logOf (started :| events))
            toSecurity = [stepTook (ReviewRows sha), stepTook (PickFinal (Picks Set.empty Map.empty))]
        it "takes the copy's outcome in its scope, to the copy's next state" $
            atName <$> securityRun (toSecurity <> [tookIn securityScope (ReviewRows sha)]) `shouldBe` Right (Just (StateName "security/pick"))
        it "records the copy's outcome named bare in the copy's scope, where only the copy takes it" $
            (\state -> inScope securityGraph state (stepTook (ReviewRows sha))) <$> securityRun toSecurity `shouldBe` Right (tookIn securityScope (ReviewRows sha))
        it "records an outcome named bare as named where an edge takes it so" $
            (\state -> inScope securityGraph state (stepTook (ReviewRows sha))) <$> securityRun [] `shouldBe` Right (stepTook (ReviewRows sha))
        it "refuses the copy's outcome named bare: it is the other review's" $
            securityRun (toSecurity <> [stepTook (ReviewRows sha)]) `shouldSatisfy` \case
                Left (NoEdge _ _) -> True
                _ -> False

    describe "a choice's pick" $ do
        let routeRun flowGraph events = replay flowGraph (logOf (started :| events))
            scopedRoute = either (error . show) id (graph (Scope "x" threeWay))
            x = scopePath "x"
            picked scope = Took scope . threeWayPick . OutcomeName
        it "moves into the branch the pick names" $
            atName <$> routeRun threeWayGraph [picked mempty "big"] `shouldBe` Right (Just (StateName "big/refactor"))
        it "refuses a pick of a label the choice lacks: the chief's route.engineer" $
            routeRun threeWayGraph [Took mempty (pickOf "route" "engineer")] `shouldSatisfy` \case
                Left (NoEdge _ _) -> True
                _ -> False
        it "runs a scoped choice from its scoped pick to the end" $
            (.at) <$> routeRun scopedRoute [picked x "small", tookIn x (DescribeDone sha)] `shouldBe` Right Out

    it "runs a scoped choice's actions, then leaves it by its scoped enough" $ do
        let scopedGather = either (error . show) id (graph (Scope "x" Library.gather))
            x = scopePath "x"
            inGather = scopePath "x/gather"
        (.at) <$> replay scopedGather (logOf (started :| [Took x (pickOf "gather" "research"), tookIn inGather ResearchSpawned, tookIn inGather ResearchHandedBack, Took x (pickOf "gather" "enough"), tookIn inGather NotesDone])) `shouldBe` Right Out

    describe "two scoped copies of one fan-out" $ do
        let copiesRun events = replay scopedFans (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| events))
            inA = tookIn (scopePath "a")
            settled =
                [ inA (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [])))
                , Spawned (childOf "c1" "t1")
                , HandedBack (runId "c1") (Finished (oneLine "PR #1"))
                , TaskMoved (TaskId "t1") (Merged (Url "pr"))
                , inA (MergeNextRound engineers)
                , stepTook (PlanDone "plan.md")
                ]
        it "starts the second copy with none of the first's tasks" $
            (\state -> (atName state, map (.id) (currentFan state).tasks)) <$> copiesRun settled
                `shouldBe` Right (Just (StateName "b/breakdown"), [])

    it "runs the engineer flow's happy path to its end" $
        (.at) <$> replay g (logOf (started :| fuelSet Balanced : happyPath)) `shouldBe` Right Out

    it "every_accepted_log_is_a_path" . hedgehog $ do
        events <- forAll genCandidate
        case replay g (logOf (started :| events)) of
            Left _ -> cover 10 "refused" True
            Right state -> do
                cover 20 "accepted" True
                cover 5 "reached the end" (state.at == Out)
                path <- evalMaybe (ty g [tookEvent scope took | Took scope took <- events, not (handsBack took)])
                assert (composes path)

    it "records_every_event_as_named_outside_any_scope" . hedgehog $ do
        flow <- forAll (Gen.element [g, tenXGraph])
        events <- forAll (genAcceptedOn [] flow)
        state <- evalEither (replay flow (logOf (started :| events)))
        event <- forAll (Gen.element (events <> happyPath))
        inScope flow state event === event

    it "every_accepted_log_of_a_scoped_flow_is_a_path" . hedgehog $ do
        AnyFlow f <- forAll (Gen.filter builds genFlow)
        flow <- evalEither (graph f)
        events <- forAll (genAcceptedOn (concatMap flowOutcomes (termSteps f)) flow)
        cover 10 "a step's outcome inside a scope" (or [scope /= mempty | Took scope _ <- events])
        path <- evalMaybe (ty flow [tookEvent scope took | Took scope took <- events, not (handsBack took)])
        assert (composes path)

    it "never_spends_past_a_cap" . hedgehog $ do
        events <- forAll genAccepted
        states <- traverse (evalEither . replay g . logOf) (NonEmpty.toList (NonEmpty.inits1 (started :| events)))
        let held = [budget | state <- states, budget <- Map.elems (budgets g state)]
        cover 1 "a used-up budget" (any usedUp held)
        for_ held $ \budget -> assert (all (budget.spent <=) budget.allows)

    -- At the pick, before the fixer runs, so the run can still take the loop's exit.
    it "refuses a re-review past Low's one at the loop pick" $
        replay g (logOf (started :| fuelSet Low : toReview <> reviewRounds [[], []]))
            `shouldSatisfy` outOf "Re-reviews" 1

    it "takes the loop's exit at Low's used-up pick" $
        atName <$> replay g (logOf (started :| fuelSet Low : toReview <> reviewRounds [[]] <> [stepTook (FixDone commit), stepTook (ReReviewRows sha), stepTook (PickFinal (Picks Set.empty Map.empty))]))
            `shouldBe` Right (Just (StateName "describe"))

    -- An Unverified requirement is a verdict, never a row (#440).
    it "takes a final pick with no row and an Unverified verdict to describe" $
        atName <$> replay g (logOf (started :| fuelSet Balanced : toReview <> [stepTook (ReviewRows sha), stepTook (PickFinal (Picks Set.empty (Map.singleton (Requirement "R1") Unverified)))]))
            `shouldBe` Right (Just (StateName "describe"))

    describe "a stuck review loop" $ do
        let stuckAtFix = toReview <> reviewRounds [["A"], ["A"]]
            askStuck = Asked (Asking (Question (QId run 1) Ask.Stuck (oneLine "the fix loop repeats A")) (StateName "fix") Itself)
            final = stepTook (PickFinal (Picks (Set.singleton (Label "A")) Map.empty))
        it "exits by pick.final at fix once Stuck was asked there" $
            atName <$> replay g (logOf (started :| fuelSet Balanced : stuckAtFix <> [askStuck, final]))
                `shouldBe` Right (Just (StateName "describe"))

        it "refuses pick.final at fix before Stuck was asked" $
            replay g (logOf (started :| fuelSet Balanced : stuckAtFix <> [final])) `shouldSatisfy` \case
                Left (NoEdge _ _) -> True
                _ -> False

        it "refuses pick.final at fix once the run moved on from the Stuck ask" $
            replay g (logOf (started :| fuelSet Balanced : stuckAtFix <> [askStuck, stepTook (FixDone commit), stepTook (ReReviewRows sha), stepTook (PickLoop (Picks Set.empty Map.empty)), final])) `shouldSatisfy` \case
                Left (NoEdge _ _) -> True
                _ -> False

    it "stuck_after_two_same_rounds" . hedgehog $ do
        -- Up to Max's 5 re-reviews, each a pick of the loop.
        rows <- forAll (Gen.list (Range.linear 1 5) (Gen.subsequence ["A", "B", "C"]))
        state <- evalEither (replay g (logOf (started :| fuelSet Max : toReview <> reviewRounds rows)))
        let expected = case reverse rows of
                current : previous : _ -> Set.map (Row . Label) (Set.fromList current `Set.intersection` Set.fromList previous)
                _ -> Set.empty
        cover 10 "stuck" (not (Set.null expected))
        stuck state === [Stuck "fix" expected | not (Set.null expected)]

    it "is not stuck on rows alternating A, B, A, B: only rounds in a row count" $
        stuck <$> replay g (logOf (started :| fuelSet Max : toReview <> reviewRounds [["A"], ["B"], ["A"], ["B"]]))
            `shouldBe` Right []

    it "is stuck on one failing check in two CI rounds in a row" $ do
        let red = stepTook (AwaitCiRed sha (Check "lint" :| []))
        stuck <$> replay g (logOf (started :| fuelSet Balanced : toCi <> [red, stepTook (FixPrDone sha), red]))
            `shouldBe` Right [Stuck "ci" (Set.singleton (Failing (Check "lint")))]

    -- Green is CI's own outcome: a stuck CI loop never claims it without CI.
    it "refuses await_ci.green at fix_pr once Stuck was asked there" $ do
        let red = stepTook (AwaitCiRed sha (Check "lint" :| []))
            askStuck = Asked (Asking (Question (QId run 1) Ask.Stuck (oneLine "the ci loop repeats lint")) (StateName "fix_pr") Itself)
        replay g (logOf (started :| fuelSet Balanced : toCi <> [red, stepTook (FixPrDone sha), red, askStuck, stepTook (AwaitCiGreen sha)])) `shouldSatisfy` \case
            Left (NoEdge _ _) -> True
            _ -> False

    it "forgets a loop's rounds once the run leaves it" $
        stuck <$> replay g (logOf (started :| fuelSet Max : toReview <> reviewRounds [["A"], ["A"]] <> [stepTook (FixDone commit), stepTook (ReReviewClean sha)]))
            `shouldBe` Right []

    it "restarts gathering in each round of the plan loop: entered afresh, then back at its pick once" $ do
        let gather = spawnedIn "gather" <> [stepTook ResearchHandedBack]
            gathered = concat (replicate 4 gather) <> enoughIn "gather" <> map (Took mempty) [outcome (PlanDone "p"), runOf "simplify_plan", outcome SimplifyPlanDone, outcome ConfirmAdjusted] <> gather
        Map.map length . (.rounds) <$> replay g (logOf (started :| fuelSet Balanced : gathered))
            `shouldBe` Right (Map.fromList [("gather", 2), ("plan", 2)])

    gatherBudgets
    tenXRounds
    architectRun
    chiefRequests

    it "append_is_idempotent_by_id" . hedgehog $ do
        events <- forAll genAccepted
        let logged = logOf (started :| events)
        state <- evalEither (replay g logged)
        again <- forAll (Gen.element (NonEmpty.toList logged))
        append g state again === Right AlreadyLogged

    it "logs a hook record fired twice once" $ do
        let atFork = [line 1 (fuelSet Balanced), line 2 (Took mempty (pickOf "gather" "research"))]
            hook n = hookLine "ab12" n (tookIn (scopePath "gather") ResearchSpawned)
            spawned hooks = (\state -> (state.at, state.meters)) <$> replay g (line 0 started :| atFork <> hooks)
        spawned [hook 3, hook 4] `shouldSatisfy` isRight
        spawned [hook 3, hook 4] `shouldBe` spawned [hook 3]

    {- One pure handler per effect serves a live run and its replay: live
    makes the event and appends it to the log so far, as the shell's commit
    does ('appendTo'), and a replay folds the same events. The log written
    live holds voids and hooks fired again, where 'appendTo' is no 'append'.
    -}
    describe "effects, live and replayed" $ do
        it "live_appends_reach_the_run_the_log_replays" . hedgehog $ do
            (flow, written, live) <- forAll genShellLog
            let events = map (.event) (NonEmpty.toList written)
            cover 30 "a pick" (or [isPick took | Took _ took <- events])
            cover 10 "a question" (or [True | Asked _ <- events])
            cover 20 "a void" (or [True | Voided _ _ <- events])
            replay flow written === Right live

        it "replaying_a_prefix_then_appending_the_rest_is_replaying_the_whole" . hedgehog $ do
            (flow, written, _) <- forAll genShellLog
            k <- forAll (Gen.int (Range.linear 1 (length written)))
            let (before, rest) = NonEmpty.splitAt k written
            prefix <- evalMaybe (NonEmpty.nonEmpty before)
            (replay flow prefix >>= \state -> appendAll flow prefix state rest) === replay flow written

        it "a_pick_replayed_off_its_choice_is_refused" . hedgehog $ do
            flow <- forAll (Gen.element roleGraphs)
            events <- forAll (genAcceptedOn [] flow)
            let picks = [(take k events, scope, took, drop (k + 1) events) | (k, Took scope took) <- zip [0 :: Int ..] events, isPick took]
            (before, scope, took, after) <- if null picks then discard else forAll (Gen.element picks)
            other <- forAll (Gen.element [o | o <- drawnOutcomes, isPick o, (outcomeEvent o).step /= (outcomeEvent took).step])
            case replay flow (logOf (started :| before <> [Took scope other] <> after)) of
                Left (NoEdge _ _) -> success
                refused -> annotateShow refused >> failure

        it "the_answer_that_came_down_is_the_answer_the_run_holds" . hedgehog $ do
            (state, logged) <- forAll genAskLog
            let answers = [(qid, text) | Answered qid text _ <- NonEmpty.toList logged]
            cover 5 "an answer" (not (null answers))
            map (heldAnswer state . fst) answers === map (Just . snd) answers

        it "an_answer_to_a_question_never_asked_is_refused" . hedgehog $ do
            (state, logged) <- forAll genAskLog
            let unasked = QId run 1000
            case replay g (logOf (logged <> pure (Answered unasked "yes" TheUser))) of
                Left (NotPending qid) -> qid === unasked
                Left (AfterStop _) -> state.stopped /== Nothing
                refused -> annotateShow refused >> failure

        it "granting_focus_leaves_the_run_where_it_is" . hedgehog $ do
            (flow, logged) <- forAll genEffectLog
            state <- evalEither (replay flow (logOf logged))
            handle FocusHere flow state Focused === Right state

    describe "a void" $ do
        it "a_void_replays_as_the_line_never_logged" . hedgehog $ do
            events <- forAll genAccepted
            let logged = logOf (started :| events)
                lastSeq = fromIntegral (length events)
            -- The last line, logged in error just now, is the void a run makes most.
            target <- forAll (Gen.frequency [(1, pure lastSeq), (4, Gen.integral (Range.linear 0 lastSeq))])
            state <- evalEither (replay g logged)
            let without = maybe (Left NotStarted) (replay g) (NonEmpty.nonEmpty (NonEmpty.filter ((/= target) . (.seq)) logged))
                voided = appendTo g state logged (line (lastSeq + 1) (Voided target "logged in error"))
            cover 5 "the log without it replays" (isRight without)
            cover 5 "the log without it does not" (not (isRight without))
            (unseenIn <$> voided) === either (Left . VoidBreaks target) (Right . Appended . unseen) without
        it "refuses a seq no line the run replays has: none, a voided one, a void" $ do
            let logged = line 0 started :| [line 1 (fuelSet Max), line 2 (Voided 1 "set by mistake")]
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
        replay g (logOf (started :| fuelSet Balanced : [stepTook (ReviewClean sha)])) `shouldBe` Left (NoEdge (At gatherPlace) (outcomeEvent (outcome (ReviewClean sha))))

    it "sets the run's Fuel at its root's Fuel step, then gathers" $
        (\state -> (fuelOf state, state.at)) <$> replay g (logOf (started :| [fuelSet Low])) `shouldBe` Right (Low, At gatherPlace)

    it "refuses a Fuel anywhere but a Fuel step, as any event with no edge there" $
        [replay flow (logOf (started :| [fuelSet Max, Overridden (placeName place) "moved", fuelSet Low])) | flow <- [g, tenXGraph], place <- Set.toList (places flow), placeName place /= stepName Fuel]
            `shouldSatisfy` all (either (\case NoEdge _ event -> event == outcomeEvent (outcome (LevelSet Low)); _ -> False) (const False))

    it "takes no event after a stop" $
        replay g (logOf (started :| fuelSet Balanced : [Stopped stop, stepTook ResearchSpawned])) `shouldBe` Left (AfterStop stop)

    it "logs a refusal after a stop" $
        (.refused) <$> replay g (logOf (started :| fuelSet Balanced : [Stopped stop, Refused note])) `shouldBe` Right (Just note)

    it "warns of a refusal until the next event" $
        (.refused) <$> replay g (logOf (started :| fuelSet Balanced : [Refused note, Took mempty (pickOf "gather" "research")])) `shouldBe` Right Nothing

    it "refuses a line of another run" $
        replay g (line 0 started :| [ofRun (runId "other") (line 1 (stepTook ResearchSpawned))]) `shouldBe` Left (OtherRun (runId "other"))

    it "overrides to a named state" $
        atName <$> replay g (logOf (started :| fuelSet Balanced : [Overridden (StateName "review") "why"])) `shouldBe` Right (Just (StateName "review"))

    it "refuses an override to a state the flow does not have" $
        replay g (logOf (started :| fuelSet Balanced : [Overridden (StateName "nowhere") "why"])) `shouldBe` Left (NoSingleState (StateName "nowhere"))

    questions
  where
    note = Note "no edge" "state next"
    stop = Stop Blocked "why"

-- | The engineer's gather, past its Fuel step.
gatherPlace :: Place
gatherPlace = Set.findMin (Set.filter ((== StateName "gather") . placeName) (places g))

ofRun :: RunId -> Envelope -> Envelope
ofRun other (Envelope source n ts _ sha' session event) = Envelope source n ts other sha' session event

-- | From the start to the first review.
toReview :: [Event]
toReview = take 13 happyPath

-- | From the start to the first CI result.
toCi :: [Event]
toCi = take 13 happyPath <> map (Took mempty) [outcome (ReviewClean sha), outcome (DescribeDone sha), outcome (SimplifyPrDone sha)]

-- | Fix rounds that pick these rows, as 'pickRounds'.
reviewRounds :: [[Text]] -> [Event]
reviewRounds = pickRounds . map (\rows -> Picks (Set.fromList (map Label rows)) Map.empty)

-- | A review with rows, then a round per pick, fixed and re-reviewed before the next; the last ends at its pick.
pickRounds :: [Picks] -> [Event]
pickRounds = \case
    [] -> []
    picks -> stepTook (ReviewRows sha) : intercalate [stepTook (FixDone commit), stepTook (ReReviewRows sha)] [[stepTook (PickLoop p)] | p <- picks]

-- | The state the run is at, by its name.
nameAt :: RunState -> Maybe Text
nameAt state = case state.at of
    At place -> Just (stateNameText (placeName place))
    Out -> Nothing
    Graph.Exit -> Nothing

-- | Refused as a spend past the named meter's cap, which allows this many at the run's Fuel.
outOf :: Text -> Natural -> Either Fold.Refusal a -> Bool
outOf meter most = \case
    Left (OutOfBudget cap n) -> someMeterName cap.meter == meter && n == most
    _ -> False

{- | Any Fuel, then a walk to the end, sometimes with an event from anywhere
in the flow. The walk takes no skip its Fuel never makes, which the fold
refuses: a walk's shortest way on is a skip, so most walks would be refused.
The level is set first, in place of the walk's own Fuel step; an await's
edges take no event, and each researcher hands back at once.
-}
genCandidate :: Gen [Event]
genCandidate = do
    fuel <- Gen.enumBounded
    walk <- filter (`Set.notMember` unwalked) <$> genWalk g {edges = Map.filterWithKey (\(from, event) _ -> fuelTakes fuel from.name event) g.edges}
    noise <- Gen.element (Set.toList outcomeNames)
    at <- Gen.int (Range.linear 0 (length walk))
    names <- Gen.element [walk, take at walk <> [noise] <> drop at walk]
    events <- traverse took names
    pure (fuelSet fuel : concatMap handedBackAtOnce events)
  where
    -- Every level's Fuel step takes one edge name: the level is the outcome's data.
    unwalked = Set.insert (outcomeEvent (outcome (LevelSet Balanced))) awaitNames
    took name = let (scope, bare) = unqualify (stateNameText name.step) in Took scope <$> outcomeOf (EventName (StateName bare) name.outcome)
    awaitNames = Set.fromList [name | ((from, name), _) <- Map.toList g.edges, isJust (unrecorded g from)]
    handedBackAtOnce event = case event of
        Took _ spawned | outcomeEvent spawned == outcomeEvent (outcome ResearchSpawned) -> [event, stepTook ResearchHandedBack]
        _ -> [event]

-- | A researcher's hand-back: it closes its fork wherever the run is, by no edge, so a path leaves it out.
handsBack :: AnyOutcome -> Bool
handsBack took = outcomeEvent took == outcomeEvent (outcome ResearchHandedBack)

{- | The gather's choice: researchers spawned in the background and
questions asked, as the agent picks; neither budget spends the other,
@extend@ grants both again, each entry into the choice starts both afresh,
and @enough@ waits at the researchers' await for every one to hand back,
then merges their notes.
-}
gatherBudgets :: Spec
gatherBudgets = describe "the gather's choice" $ do
    it "asks 20 questions at Balanced, spending no researcher" $
        replay g (logOf (started :| fuelSet Balanced : spawns 5 <> asks 1 20)) `shouldSatisfy` isRight

    it "refuses the question past Balanced's 30" $
        replay g (logOf (started :| fuelSet Balanced : asks 1 31)) `shouldSatisfy` outOf "Interview questions" 30

    it "takes a Stuck question past the questions, as asking whether to go on" $
        replay g (logOf (started :| fuelSet Balanced : interviewed ([askAt i Fact | i <- [1 .. 30]] <> [askAt 31 Ask.Stuck]))) `shouldSatisfy` isRight

    it "refuses the interview's pick once its questions are used up, as the advice offers it no more" $
        replay g (logOf (started :| fuelSet Balanced : asks 1 30 <> interviewed [])) `shouldSatisfy` outOf "Interview questions" 30

    it "counts no question asked off the gather" $
        replay g (logOf (started :| fuelSet Balanced : enoughIn "gather" <> [askAt i Fact | i <- [1 .. 31]])) `shouldSatisfy` isRight

    for_ [(Low, 1), (Balanced, 5)] $ \(fuel, allowed) ->
        it ("spawns " <> show allowed <> " researchers at " <> show fuel <> " and refuses the next") $ do
            replay g (logOf (started :| fuelSet fuel : spawns allowed)) `shouldSatisfy` isRight
            replay g (logOf (started :| fuelSet fuel : spawns (allowed + 1))) `shouldSatisfy` outOf "Researchers" (fromIntegral allowed)

    it "spawns a researcher per group of the plan at Max, as many as the agent counts" $
        replay g (logOf (started :| fuelSet Max : spawns 12)) `shouldSatisfy` isRight

    it "takes hand-backs in any order between questions, then leaves by enough" $
        atName <$> replay g (logOf (started :| fuelSet Balanced : spawns 2 <> asks 1 2 <> [handedBack] <> spawns 1 <> asks 3 1 <> [handedBack, handedBack] <> enoughIn "gather"))
            `shouldBe` Right (Just (StateName "plan"))

    it "takes a researcher's hand-back while the interview asks, as the researcher runs in the background" $
        atName <$> replay g (logOf (started :| fuelSet Balanced : spawns 1 <> [pickInterview, askAt 1 Fact, handedBack, askAt 2 Fact]))
            `shouldBe` Right (Just (StateName "interview"))

    it "waits at the researchers' await after enough while one is open, then merges the notes once it hands back" $ do
        let waiting = spawns 2 <> [handedBack, pickEnough]
        map (fmap atName . replay g . logOf . (started :|) . (fuelSet Balanced :)) [waiting, waiting <> [handedBack], waiting <> [handedBack, notesDone]]
            `shouldBe` map (Right . Just . StateName) ["gather/researchers", "gather/notes", "plan"]

    it "refuses the notes while a researcher is open" $
        replay g (logOf (started :| fuelSet Balanced : spawns 2 <> [handedBack, pickEnough, notesDone])) `shouldSatisfy` \case
            Left _ -> True
            Right _ -> False

    it "reaches the same await, rounds and ledgers in whatever order the researchers hand back" . hedgehog $ do
        n <- forAll (Gen.int (Range.linear 1 5))
        early <- forAll (Gen.int (Range.linear 0 n))
        interleaved <- forAll (genHandBacks n early 0)
        let gathered events = (\state -> (state.at, state.rounds, state.meters)) <$> replay g (logOf (started :| fuelSet Balanced : events))
        annotate (show interleaved)
        gathered (interleaved <> [pickEnough] <> replicate (n - early) handedBack)
            === gathered (spawns n <> [pickEnough] <> replicate n handedBack)

    it "takes a researcher's hand-back before its bind, which closes nothing: its return does" $ do
        let early = spawnedIn "gather" <> [stepTook ResearchHandedBack, bind, pickEnough]
        map (fmap atName . replay g . logOf . (started :|) . (fuelSet Balanced :)) [early, early <> [handedBack]]
            `shouldBe` map (Right . Just . StateName) ["gather/researchers", "gather/notes"]

    it "keeps every bound child in the ledger, oldest first, until its own return, whatever comes between" . hedgehog $ do
        events <- forAll (merged . concat =<< traverse lifetime [1 .. 6])
        for_ (inits events) $ \prefix -> do
            state <- evalEither (replay g (logOf (started :| fuelSet Balanced : prefix)))
            let back = [agent | WorkerReturned _ (Just agent) <- prefix]
            map (.child) (ledger g state) === [AgentChild agent | WorkerSpawned _ agent <- prefix, agent `notElem` back]

    it "completes the researchers' await iff every researcher it waits on returned, whatever the order of other roles' events" . hedgehog $ do
        n <- forAll (Gen.int (Range.linear 1 4))
        others <- forAll (Gen.list (Range.linear 0 4) (Gen.element [AgentRole "implementer", AgentRole "fixer", AgentRole "refactorer"]))
        let researchersOpen = [spawnedIn "gather" <> [WorkerSpawned researcher (agentNo i)] | i <- [1 .. n]]
            othersOpen = [WorkerSpawned role (agentNo i) | (i, role) <- zip [100 ..] others]
        after <- forAll (merged ([[WorkerReturned researcher (Just (agentNo i))] | i <- [1 .. n]] <> [[WorkerReturned role (Just (agentNo i))] | (i, role) <- zip [100 ..] others] <> [[stepTook ResearchHandedBack] | _ <- [1 .. n]]))
        for_ (inits after) $ \prefix -> do
            state <- evalEither (replay g (logOf (started :| fuelSet Balanced : concat researchersOpen <> othersOpen <> [pickEnough] <> prefix)))
            let open = n - length [() | WorkerReturned role _ <- prefix, role == researcher]
            atName state === Just (StateName (if open > 0 then "gather/researchers" else "gather/notes"))

    it "takes a researcher's hand-back anywhere, closing nothing" $
        atName <$> replay g (logOf (started :| fuelSet Balanced : spawns 1 <> [stepTook ResearchHandedBack, stepTook ResearchHandedBack, pickEnough]))
            `shouldBe` Right (Just (StateName "gather/researchers"))

    it "grants another 5 researchers and 30 questions after extend, keeping the open ones" $ do
        let extended = spent <> [Extended "the user goes on"] <> asks 31 30 <> spawns 5
        replay g (logOf (started :| fuelSet Balanced : extended <> interviewed [askAt 61 Fact])) `shouldSatisfy` outOf "Interview questions" 30
        replay g (logOf (started :| fuelSet Balanced : extended <> spawns 1)) `shouldSatisfy` outOf "Researchers" 5
        atName <$> replay g (logOf (started :| fuelSet Balanced : extended <> replicate 9 handedBack <> [pickEnough])) `shouldBe` Right (Just (StateName "gather/researchers"))
        atName <$> replay g (logOf (started :| fuelSet Balanced : extended <> replicate 10 handedBack <> enoughIn "gather")) `shouldBe` Right (Just (StateName "plan"))

    it "starts both budgets afresh when the run gathers again after an adjusted plan" $ do
        let adjusted = spent <> replicate 5 handedBack <> enoughIn "gather" <> [stepTook (PlanDone "p"), Took mempty (runOf "simplify_plan"), stepTook SimplifyPlanDone, stepTook ConfirmAdjusted]
        replay g (logOf (started :| fuelSet Balanced : adjusted <> asks 31 30 <> spawns 5)) `shouldSatisfy` isRight

    it "keeps each gap recorded, oldest first, and stays where it is" $ do
        let at = fuelSet Balanced : take 7 happyPath
        fmap (\state -> (state.at, state.gaps)) (replay g (logOf (started :| at <> [Gapped "one", Gapped "two"])))
            `shouldBe` fmap (\state -> (state.at, ["one", "two"])) (replay g (logOf (started :| at)))

    it "refuses extend outside the gather" $
        replay g (logOf (started :| fuelSet Balanced : take 10 happyPath <> [Extended "why"])) `shouldBe` Left NothingToExtend
  where
    -- Each spawn bound to its agent, as the bind hook logs it: its entry in the ledger.
    spawns n = concat (replicate n (spawnedIn "gather" <> [bind]))
    bind = WorkerSpawned researcher (AgentId "r")
    -- A researcher's return closes its entry: the oldest of its role, as a hand-back by hand names no id.
    handedBack = WorkerReturned researcher Nothing
    researcher = AgentRole "researcher"
    pickInterview = Took mempty (pickOf "gather" "interview")
    pickEnough = Took mempty (pickOf "gather" "enough")
    notesDone = tookIn (scopePath "gather") NotesDone
    -- Balanced's researchers and questions, all used.
    spent = spawns 5 <> asks 1 30
    asks from n = interviewed [askAt i Fact | i <- [from .. from + n - 1]]
    askAt n kind = Asked (Asking (Question (QId run n) kind (oneLine "a question")) (StateName "interview") Itself)
    agentNo i = AgentId ("a" <> Text.pack (show (i :: Int)))
    -- An agent of any role bound, then returned by its id or never, and a hand-back that closes nothing: each its own lane.
    lifetime i = do
        role <- Gen.element [researcher, AgentRole "implementer", AgentRole "fixer"]
        returns <- Gen.bool
        reports <- Gen.bool
        pure ([WorkerSpawned role (agentNo i) : [WorkerReturned role (Just (agentNo i)) | returns]] <> [[stepTook ResearchHandedBack] | reports])
    -- The lanes' events merged in any order, each lane's in its own.
    merged :: [[Event]] -> Gen [Event]
    merged lanes = case filter (not . null) lanes of
        [] -> pure []
        open -> do
            i <- Gen.int (Range.constant 0 (length open - 1))
            case splitAt i open of
                (before, (next : rest) : after) -> (next :) <$> merged (before <> (rest : after))
                _ -> pure []
    -- These spawns and hand-backs in any order a run may record them: a hand-back only while one is open.
    genHandBacks :: Int -> Int -> Int -> Gen [Event]
    genHandBacks toSpawn toHandBack open = case (toSpawn > 0, toHandBack > 0 && open > 0) of
        (False, False) -> pure []
        (True, False) -> spawned
        (False, True) -> handed
        (True, True) -> Gen.choice [spawned, handed]
      where
        spawned = ((spawnedIn "gather" <> [bind]) <>) <$> genHandBacks (toSpawn - 1) toHandBack (open + 1)
        handed = (handedBack :) <$> genHandBacks toSpawn (toHandBack - 1) (open - 1)

-- | The interview picked at the gather, these questions asked at it, then back at the pick.
interviewed :: [Event] -> [Event]
interviewed asked = Took mempty (pickOf "gather" "interview") : asked <> [stepTook InterviewAsked]

{- | The architect's run: research and the problem until the user understands
it, design rounds until the user confirms one, and only then the ticket's url.
-}
architectRun :: Spec
architectRun = describe "the architect's run" $ do
    it "researches, understands the problem, adjusts the design once, then keeps the confirmed design's ticket url" $
        (\state -> (state.at, state.ticket)) <$> architect (problemUnderstood <> designRound ConfirmDesignAdjusted <> designRound (ConfirmDesignConfirmed ticketUrl))
            `shouldBe` Right (Out, Just ticketUrl)

    it "researches again after the problem needs more" $
        nameAt <$> architect (researchedIn "exploring" <> enoughIn "exploring" <> [stepTook ProblemMore]) `shouldBe` Right (Just "exploring")

    it "refuses a fourth problem round at Balanced's three" $
        architect (concat (replicate 4 (enoughIn "exploring" <> [stepTook ProblemMore]))) `shouldSatisfy` outOf "Problem rounds" 3

    it "refuses a fourth adjusted design at Balanced's three rounds" $
        architect (problemUnderstood <> concat (replicate 4 (designRound ConfirmDesignAdjusted))) `shouldSatisfy` outOf "Design rounds" 3

    it "accepts a fourth adjusted design after extend" $ do
        let extended = problemUnderstood <> concat (replicate 3 (designRound ConfirmDesignAdjusted)) <> designDiscussed <> [Extended "the user goes on"]
        architect (extended <> [stepTook ConfirmDesignAdjusted]) `shouldSatisfy` isRight

    it "records_no_ticket_url_before_the_design_is_confirmed" . hedgehog $ do
        events <- forAll (genAcceptedOn [] architectGraph)
        let (unconfirmed, rest) = break confirmed events
        cover 5 "the design confirmed" (not (null rest))
        states <- traverse (evalEither . replay architectGraph . logOf) (NonEmpty.toList (NonEmpty.inits1 (started :| unconfirmed)))
        for_ states $ \state -> (state.ticket, state.latest) === (Nothing, Nothing)
  where
    architect events = replay architectGraph (logOf (Started (startOf ArchitectFlow (ByUser OwnPr)) :| fuelSet Balanced : events))
    designRound verdict = designDiscussed <> [stepTook verdict]
    confirmed = \case
        Took _ took -> outcomeEvent took == EventName (stepName ConfirmDesign) (OutcomeName "confirmed")
        _ -> False

{- | The chief's requests: each is picked at the hub, runs inline in its
branch's scope by the events its own skill records bare, and ends at @next@,
which takes the next request at the hub or ends the run.
-}
chiefRequests :: Spec
chiefRequests = describe "the chief's requests" $ do
    it "routes a request to the engineer, runs it inline to its PR, and names that PR at next" $
        (\state -> (nameAt state, state.latest)) <$> chief (request "engineer" <> engineered) `shouldBe` Right (Just "next", Just (Url "u"))

    it "takes the next request at its Fuel, and ends the run at next.done" $
        map (fmap nameAt . chief) [request "engineer" <> engineered <> [stepTook NextRequest], request "engineer" <> engineered <> [stepTook NextDone]]
            `shouldBe` [Right (Just "fuel"), Right Nothing]

    it "discusses a request in its scope and moves on to next when the discussion has enough" $
        nameAt <$> chief (request "discussion" <> within "discussion" (researchedIn "discussing" <> enoughIn "discussing")) `shouldBe` Right (Just "next")

    it "does a request no flow fits directly, keeping no url" $
        (\state -> (nameAt state, state.latest)) <$> chief (request "other" <> [stepTook (DirectDone "renamed a file")]) `shouldBe` Right (Just "next", Nothing)

    it "takes a new Fuel at each request's Fuel step" $
        fuelOf <$> chief (firstRequest <> [stepTook NextRequest, fuelSet Low]) `shouldBe` Right Low

    it "refuses a new Fuel inside a request" $
        chief (firstRequest <> [fuelSet Low]) `shouldSatisfy` \case
            Left (NoEdge _ event) -> event == outcomeEvent (outcome (LevelSet Low))
            _ -> False

    it "runs a whole flow's branch from its own Fuel step, the request's given again" $
        (\state -> (nameAt state, fuelOf state)) <$> chief [fuelSet Max, pick "engineer"] `shouldBe` Right (Just "engineer/fuel", Max)

    it "takes a target at a request's Fuel, the PR an earlier request recorded not its own" $
        (\state -> (state.drafted, state.published, shape state)) <$> chief (request "engineer" <> engineered <> [stepTook NextRequest, Targeted (OnPr pr)])
            `shouldBe` Right (Nothing, Nothing, RoundOn pr)

    it "refuses a target off a Fuel step" $
        chief (request "other" <> [Targeted (OnPr pr)]) `shouldBe` Left TargetOffFuel

    it "refuses a target at the Fuel of a flow run on its own: only a chief request names one" $
        replay g (logOf (started :| [Targeted (OnPr pr)])) `shouldBe` Left TargetOffFuel

    it "drops the target at the next request, which is new work again" $
        (\state -> (state.onTarget, shape state)) <$> chief (Targeted (OnPr pr) : request "other" <> [stepTook (DirectDone "done"), stepTook NextRequest]) `shouldBe` Right (Nothing, OwnPr)

    it "lets a request on a PR skip ready, as a round does, and refuses the skip with no target" $
        map (fmap nameAt . chief) [Targeted (OnPr pr) : toReadySkipped, toReadySkipped]
            `shouldBe` [Right (Just "next"), Left (NotSkippable "engineer/ready")]

    it "settles a targeted request's plan without the user until a Design or Scope question is asked" $
        map (fmap planSettled . chief) ([Targeted (OnPr pr)] : [] : [Targeted (OnPr pr) : request "engineer" <> within "engineer" [fuelSet Balanced, askIn kind] | kind <- [Fact, Design, Ask.Scope]])
            `shouldBe` [Right True, Right False, Right True, Right False, Right False]

    it "keeps a request on a branch its own PR: ready not skipped, its plan settled without the user" $
        let onBranch = Targeted (OnBranch (Branch "feature"))
         in ((\state -> (shape state, planSettled state)) <$> chief [onBranch], nameAt <$> chief (onBranch : toReadySkipped))
                `shouldBe` (Right (OwnPr, True), Left (NotSkippable "engineer/ready"))

    it "chains architect, a block and architect again through next, naming the newest url each time" $ do
        let designed = request "architect" <> within "architect" (fuelSet Balanced : problemUnderstood <> designDiscussed <> [stepTook (ConfirmDesignConfirmed ticketUrl)])
            researched = request "blocks" <> [Took mempty (pickOf "block" "researching")] <> within "researching" (researchedIn "exploring" <> enoughIn "exploring")
            shipped = request "blocks" <> [Took mempty (pickOf "block" "shipping")] <> within "shipping" [stepTook (OpenPrDone pr), stepTook (AwaitCiGreen sha), stepTook (ReadyDone pr)]
            andThen first later = first <> [stepTook NextRequest] <> later
        map (fmap (\state -> (nameAt state, state.latest)) . chief) [designed, designed `andThen` researched, designed `andThen` shipped, shipped `andThen` designed]
            `shouldBe` [Right (Just "next", Just ticketUrl), Right (Just "next", Just ticketUrl), Right (Just "next", Just pr), Right (Just "next", Just ticketUrl)]
  where
    chief events = replay chiefGraph (logOf (Started (startOf ChiefFlow (ByUser OwnPr)) :| events))
    -- A request: its Fuel, then its pick.
    request branch = [fuelSet Balanced, pick branch]
    pick branch = Took mempty (pickOf "route" branch)
    engineered = within "engineer" (fuelSet Balanced : happyPath)
    pr = Url "https://github.com/o/r/pull/7"
    firstRequest = [fuelSet Max, pick "other", stepTook (DirectDone "done")]
    toReadySkipped = request "engineer" <> within "engineer" (fuelSet Balanced : init happyPath <> [stepTook (ReadySkipped pr)])
    askIn kind = Asked (Asking (Question (QId run 1) kind (oneLine "a question")) (StateName "engineer/gather") Itself)

{- | The 10x's rounds: a round task keeps its PR open, the merge ends the run
or loops back to gather for the next round, with fresh budgets.
-}
tenXRounds :: Spec
tenXRounds = describe "the 10x's rounds" $ do
    it "keeps an engineer's child run in the ledger while it runs or asks up, until it hands back its end" $ do
        let asking = HandedBack (runId "c1") (AsksUp (QId run 1))
            ledgerAfter events = ledger tenXGraph (tenXAt (plainTask "t1" [] :| []) (Spawned (childOf "c1" "t1") : events))
        map ledgerAfter [[], [asking], [HandedBack (runId "c1") (Finished (oneLine "READY"))]]
            `shouldBe` [[Open (RunChild (runId "c1")) (AgentRole "engineer")], [Open (RunChild (runId "c1")) (AgentRole "engineer")], []]

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
        tenXRun (spentAgain <> interviewed [askAt 61]) `shouldSatisfy` outOf "Interview questions" 30

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
    parent = Parent (runId "p1") t1
    engineerRun principal fuel = replay g (logOf (Started (startOf EngineerFlow principal) :| fuelSet fuel : init happyPath <> [stepTook (ReadySkipped pr)]))
    tenXRun events = replay tenXGraph (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| fuelSet Balanced : events))
    agreed = spawnedIn "gather" <> [stepTook ResearchHandedBack] <> planned
    planned = enoughIn "gather" <> [stepTook (PlanDone "p"), Took mempty (runOf "simplify_plan"), stepTook SimplifyPlanDone, stepTook ConfirmConfirmed, stepTook (BreakdownDone engineers (tasksOf (onPr :| [])))]
    onPr = roundTask "t1" "https://pr/1"
    toEngineers task = [Overridden (StateName "breakdown") "the plan is agreed", stepTook (BreakdownDone engineers (tasksOf (task :| [])))]
    settled task moved = toEngineers task <> [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "READY")), TaskMoved t1 moved]
    -- The first round spends Balanced's 5 researchers and 30 questions, then loops.
    round1 = spent 1 <> [stepTook ResearchHandedBack] <> planned <> [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "READY")), TaskMoved t1 (Kept pr), stepTook (MergeNextRound engineers)]
    -- Balanced's 5 researchers, one handed back before the round ends, and 30 questions.
    spent from = concat (replicate 5 (spawnedIn "gather")) <> replicate 4 (stepTook ResearchHandedBack) <> interviewed (map askAt [from .. from + 29])
    askAt n = Asked (Asking (Question (QId run n) Fact (oneLine "a question")) (StateName "interview") Itself)

-- | The ask events, on the engineer flow's graph: they never move the run.
questions :: Spec
questions = describe "questions" $ do
    it "keeps a question pending, oldest first, until it is ruled on or its answer comes down" $
        map (\pending -> (pending.asking.question.qid, pending.waits)) . (.pending)
            <$> replay g (logOf (started :| fuelSet Balanced : [ask 3 Design, ask 1 Design, ask 2 Pick, ask 4 Design, RuledOn (q 2) proposal, Forwarded (q 1) TheUser, Forwarded (q 4) TheUser, Answered (q 4) "yes" TheUser]))
            `shouldBe` Right [(q 3, ForTriage), (q 1, ForAnswer)]

    it "keeps the run at its step while a question waits, the step named in the log (law Resume)" $
        ((.at) <$> replay g (logOf (started :| fuelSet Balanced : [ask 1 Design, Forwarded (q 1) TheUser])), map (.asking.step) . (.pending) <$> replay g (logOf (started :| fuelSet Balanced : [ask 1 Design])))
            `shouldBe` ((.at) <$> replay g (logOf (started :| [fuelSet Balanced])), Right [StateName "implement"])

    it "ends every pending question at a stop" $
        (.pending) <$> replay g (logOf (started :| fuelSet Balanced : [ask 1 Design, Forwarded (q 1) TheUser, ask 2 Pick, Stopped halt]))
            `shouldBe` Right []

    it "refuses a ruling where the run's row forwards" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Design, RuledOn (q 1) proposal])) `shouldBe` Left (NotAllowed (MayNotRule Role.Lead Design))

    it "rules as the Orchestrator on a question asked inside a scoped 10x, under an engineer run" $
        length . (.rulings) <$> replay (scopedIn "10x" tenX) (logOf (started :| [askIn "10x/gather" Design, RuledOn (q 1) proposal]))
            `shouldBe` Right 1

    it "refuses a ruling as the Lead on a question asked inside a scoped engineer, under a 10x run" $
        replay (scopedIn "engineer" engineer) (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| [askIn "engineer/gather" Design, RuledOn (q 1) proposal]))
            `shouldBe` Left (NotAllowed (MayNotRule Role.Lead Design))

    it "refuses a forward of a question the run's row must answer, so no Fact climbs" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Fact, Forwarded (q 1) TheUser])) `shouldBe` Left (NotAllowed (MustAnswer Role.Lead Fact))

    it "refuses a ruling on a question retagged Security that names no basis" $
        replay g (logOf (Started (startOf TenXFlow (ByUser OwnPr)) :| [ask 1 Design, RetaggedSecurity (q 1), RuledOn (q 1) proposal]))
            `shouldBe` Left (NotAllowed (NoBasis (q 1)))

    it "refuses a forward to another than whoever started the run" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Design, Forwarded (q 1) parent])) `shouldBe` Left (NotAbove parent)

    it "refuses an answer to a question the run never forwarded" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Design, Answered (q 1) "yes" TheUser])) `shouldBe` Left (NotForwarded (q 1))

    it "refuses a retag once the question is forwarded" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Design, Forwarded (q 1) TheUser, RetaggedSecurity (q 1)])) `shouldBe` Left (AlreadyForwarded (q 1))

    it "refuses an event on a question not pending" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Pick, RuledOn (q 1) proposal, RuledOn (q 1) proposal])) `shouldBe` Left (NotPending (q 1))

    it "refuses asking a pending question again" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Pick, ask 1 Pick])) `shouldBe` Left (AskedTwice (q 1))

    it "refuses asking a ruled question again, so a retried relay is ruled once" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Pick, RuledOn (q 1) proposal, ask 1 Pick])) `shouldBe` Left (AskedTwice (q 1))

    it "takes an answer it holds again as no news, and refuses another" $ do
        let answered = [ask 1 Design, Forwarded (q 1) TheUser, Answered (q 1) "yes" TheUser]
        map (\more -> (.answers) <$> replay g (logOf (started :| fuelSet Balanced : answered <> more))) [[], [Answered (q 1) "yes" TheUser]]
            `shouldBe` replicate 2 (Right [Fold.Answer (Question (q 1) Design (oneLine "a question")) "yes"])
        replay g (logOf (started :| fuelSet Balanced : answered <> [Answered (q 1) "no" TheUser])) `shouldBe` Left (AnsweredOtherwise (q 1) "yes")

    it "refuses asking an answered question again" $
        replay g (logOf (started :| fuelSet Balanced : [ask 1 Design, Forwarded (q 1) TheUser, Answered (q 1) "yes" TheUser, ask 1 Design]))
            `shouldBe` Left (AskedTwice (q 1))

    it "every_ruling_is_in_show_and_in_the_handback" . hedgehog $ do
        (state, logged) <- forAll genAskLog
        let events = NonEmpty.toList logged
        let ruled = [(qid, ruling) | RuledOn qid ruling <- events]
            sent = Text.lines (handback "READY ref" state.run state.rulings)
        -- About 37% of runs: a 100-test run misses 15% on about 1 seed in 3 million.
        cover 15 "a ruling" (not (null ruled))
        map (\ruling -> (ruling.qid, ruling.proposal)) state.rulings === ruled
        for_ ruled $ \(qid, ruling) ->
            assert (any (\sentLine -> all (`Text.isInfixOf` sentLine) (qidText qid <> " " : map oneLineText [ruling.answer, ruling.why, ruling.cost])) sent)

    it "no_event_retags_security" . hedgehog $ do
        (state, logged) <- forAll genAskLog
        let events = NonEmpty.toList logged
        let security = Set.fromList ([asking.question.qid | Asked asking <- events, asking.question.kind == Security] <> [qid | RetaggedSecurity qid <- events])
            kinds =
                [pending.asking.question.kind | pending <- state.pending, Set.member pending.asking.question.qid security]
                    <> [ruling.kind | ruling <- state.rulings, Set.member ruling.qid security]
        -- About 10% of runs: a 100-test run misses 1% on about 1 seed in 40,000.
        cover 1 "a Security question ruled" (any (\ruling -> Set.member ruling.qid security) state.rulings)
        kinds === map (const Security) kinds

    it "every_ask_ends_answered_or_stopped" . hedgehog $ do
        (asker, rungs) <- forAll genChain
        question <- forAll genQuestion
        rung0 <- evalMaybe (NonEmpty.nonEmpty rungs)
        (logs, end) <- climb asker (Question (QId (NonEmpty.head rung0).run 1) question.kind question.text) rungs
        -- About 13% of runs: a 100-test run misses 1% on about 1 seed in a million.
        cover 1 "stopped" (end == Halt)
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
    askIn at kind = Asked (Asking (Question (q 1) kind (oneLine "a question")) (StateName at) Itself)
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
    fanned = Do (Breakdown engineers) :> Library.par (Group engineers (AgentRole "engineer")) engineer :> Do (Merge engineers)

{- | A flow with two fan-outs, the second a scoped copy that runs on the
first's PRs. No step goes from a PR back to a plan, so the second has no
breakdown of its own.
-}
twoFans :: OpenGraph
twoFans = either (error . show) id (graph (Do (Breakdown engineers) :> Library.par (Group engineers (AgentRole "engineer")) engineer :> Scope "second" (Library.par (Group engineers (AgentRole "engineer")) (Do SimplifyPR)) :> Do (Merge engineers)))

-- | The state a run is at, if it is at one.
atName :: RunState -> Maybe StateName
atName state = case state.at of
    At place -> Just (placeName place)
    Out -> Nothing
    Graph.Exit -> Nothing

-- | A run of this flow under this principal, with no ops.
startOf :: FlowName -> Principal -> Start
startOf flow principal = Start flow "notes" principal Set.empty

{- | Up to 60 tries at an ask event on a run of the engineer or the 10x flow,
one per rung that rules, under the user or a parent, keeping those the fold
accepts: the run state and its log, @started@ first.
-}
genAskLog :: Gen (RunState, NonEmpty Event)
genAskLog = do
    flow <- Gen.element [EngineerFlow, TenXFlow]
    principal <- Gen.element [ByUser OwnPr, ByRole (Parent (runId "p1") (TaskId "t1")) OwnPr ChildConfirms]
    let begun = Started (startOf flow principal)
    first <- either (fail . show) pure (replay g (logOf (begun :| [])))
    tries <- Gen.int (Range.linear 0 60)
    fmap (begun :|) <$> go tries first 1 0
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
            , [rung "e1" EngineerFlow (ByRole (Parent (runId "x1") (TaskId "t1")) OwnPr ChildConfirms), rung "x1" TenXFlow (ByUser OwnPr)]
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

-- | The graphs of the engineer, 10x, architect and chief flows.
roleGraphs :: [OpenGraph]
roleGraphs = [g, tenXGraph, architectGraph, chiefGraph]

{- | An accepted log with the graph it replays on: a role's steps and
picks, or the engineer's questions.
-}
genEffectLog :: Gen (OpenGraph, NonEmpty Event)
genEffectLog =
    Gen.choice
        [ Gen.element roleGraphs >>= \flow -> (flow,) . (started :|) <$> genAcceptedOn [] flow
        , (g,) . snd <$> genAskLog
        ]

-- | Whether the outcome is a choice's pick.
isPick :: AnyOutcome -> Bool
isPick = \case
    AnyOutcome PickLayer _ -> True
    AnyOutcome _ _ -> False

{- | A line the shell is sent: a new event, a void of the line logged @k@
lines back, or the hook of the line logged @k@ lines back fired again.
-}
data Sent = Fresh Event | VoidBack Int | Refire Int
    deriving stock (Show)

{- | A run's flow, the log the shell writes for it and the run the shell
holds. Between a run's events the shell also meets: a line voided just
after it is logged, its hook fired again and the event logged anew; a hook
fired twice; a void of an older line, which the run may refuse.
-}
genShellLog :: Gen (OpenGraph, NonEmpty Envelope, RunState)
genShellLog = do
    (flow, begun :| events) <- genEffectLog
    sends <- concat <$> traverse withExtras events
    (written, live) <- either (fail . show) pure (shellLog flow begun sends)
    pure (flow, written, live)
  where
    withExtras event =
        (Fresh event :)
            <$> Gen.frequency
                [ (6, pure [])
                , (1, pure [VoidBack 0, Refire 1, Fresh event])
                , (1, pure . Refire <$> Gen.int (Range.linear 0 5))
                , (1, pure . VoidBack <$> Gen.int (Range.linear 0 10))
                ]

{- | Each sent line numbered and appended to the log so far ('appendTo'), as
the shell's commit appends it ('State.Cli.Shell' exports none): a line
refused or logged already is not written. Each new line is a hook's, so a
hook fired again is the same line.
-}
shellLog :: OpenGraph -> Event -> [Sent] -> Either Fold.Refusal (NonEmpty Envelope, RunState)
shellLog flow begun sends = do
    let first = line 0 begun
    state <- replay flow (first :| [])
    Right (foldl' send (first :| [], state) sends)
  where
    send (logged, state) sent = case appendTo flow state logged envelope of
        Right (Appended later) -> (logged <> pure envelope, later)
        Right AlreadyLogged -> (logged, state)
        Left _ -> (logged, state)
      where
        next = fromIntegral (length logged)
        back k = NonEmpty.reverse logged NonEmpty.!! min k (length logged - 1)
        envelope = case sent of
            Fresh event -> hookLine (Text.pack ("d" <> show next)) next event
            VoidBack k -> line next (Voided (back k).seq "logged in error")
            Refire k -> (back k) {seq = next}

-- | The lines appended one by one to the log so far, as the shell appends them.
appendAll :: OpenGraph -> NonEmpty Envelope -> RunState -> [Envelope] -> Either Fold.Refusal RunState
appendAll flow logged state = \case
    [] -> Right state
    envelope : rest ->
        appendTo flow state logged envelope >>= \case
            Appended later -> appendAll flow (logged <> pure envelope) later rest
            AlreadyLogged -> appendAll flow logged state rest
