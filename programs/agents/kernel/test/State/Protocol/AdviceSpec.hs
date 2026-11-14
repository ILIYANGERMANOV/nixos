module State.Protocol.AdviceSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Doubles.Gh (printedPr)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Flow (FanId (..))
import State.Category.Mode (Quality (..), Size (..))
import State.Protocol.Advice
import State.Run.Ask (Above (..), Kind (..), Proposal (..), QId (..), Question (..))
import State.Run.Event hiding (Stopped)
import State.Run.EventGen (genStart, genText, oneLine, run, runId, start)
import State.Run.RunGen (childOf, commit, g, genAccepted, happyPath, loadSteps, plainTask, runAt, runUnder, sha, tenXAt, tenXGraph)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome)
import State.Step.Fan (Outcome (..))
import State.Step.Gather (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..))
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Protocol.Advice" $ do
    steps <- runIO loadSteps
    let next facts = (.action) . advise steps facts

    it "advice_is_equal_under_any_principal_up_to_delivery" . hedgehog $ do
        events <- forAll genAccepted
        facts <- forAll genFacts
        one <- forAll genStart
        other <- forAll genStart
        let under from = runUnder start {principal = from.principal, interface = from.interface} events
            decided state = (due g facts state, advise steps facts state)
        decided (under one) === decided (under other)

    describe "pullRequestOf" $ do
        it "reads back the PR gh prints" . hedgehog $ do
            pr <- forAll genPullRequest
            pullRequestOf (printedPr pr) === Right (Just pr)

        it "reads gh's no-PR failure as no PR" $
            pullRequestOf (PrViewFailed "no pull requests found for branch \"b\"\n") `shouldBe` Right Nothing

        it "says why GitHub was not read" $
            map
                pullRequestOf
                [ PrViewTimedOut 10
                , PrViewFailed "error connecting to api.github.com\ncheck your internet connection\n"
                , PrViewPrinted "{\"url\":\"u\",\"baseRefName\":\"main\",\"headRefName\":\"b\",\"isDraft\":false,\"state\":\"LOCKED\"}"
                ]
                `shouldBe` [ Left "gh pr view timed out after 10s"
                           , Left "gh pr view: error connecting to api.github.com"
                           , Left "gh pr view printed no PR: Error in $: unknown PR state LOCKED"
                           ]

    describe "pick" $ do
        it "offers pick.loop while a review round is left" $
            next noFacts (atPick Normal [])
                `shouldSatisfy` runs ("state record pick.loop" `Text.isPrefixOf`)

        it "offers Trivial's one review pick.loop only with a Not met" $
            next noFacts (atPick Trivial [])
                `shouldSatisfy` runs (\command -> "state record pick.final" `Text.isPrefixOf` command && "only with a not-met verdict" `Text.isInfixOf` command)

        it "offers only pick.final once no review round is left" $
            next noFacts (atPick Trivial [stepTook (PickLoop notMet), stepTook (FixDone commit), stepTook (ReviewRows sha)])
                `shouldSatisfy` runs (\command -> "state record pick.final" `Text.isPrefixOf` command && not ("pick.loop" `Text.isInfixOf` command))

    describe "confirm" $ do
        it "asks Confirm at confirm" $
            next noFacts atConfirm `shouldSatisfy` \case
                Ask Confirm _ -> True
                _ -> False

        it "asks Confirm once, then advises its outcome" $ do
            let (question, asked, _) = ownAsk atConfirm Confirm (oneLine "the plan holds?")
                answered = runAt (knobs Balanced Normal <> map Took (take 4 happyPath) <> asked <> [Answered question.qid "confirmed" TheUser])
            next noFacts answered `shouldBe` Run "state record confirm.confirmed | state record confirm.adjusted"

    describe "due" $ do
        it "skips research in Trivial" $
            due g noFacts (runAt (knobs Balanced Trivial)) `shouldBe` Just (outcome ResearchSkipped)

        it "skips the refactor at or below its changed lines" $
            due g noFacts {changedLines = Just 100} atRefactor
                `shouldBe` Just (outcome (RefactorSkipped "100 changed lines, at or below 100"))

        it "runs the refactor above its changed lines, or when they are unknown" $
            map (\changed -> due g noFacts {changedLines = changed} atRefactor) [Just 101, Nothing] `shouldBe` [Nothing, Nothing]

        it "records the draft PR GitHub already has" $
            due g withPr {pr = Just (PullRequest draftPr IsDraft)} (runAt (knobs Balanced Normal <> map Took (take 5 happyPath)))
                `shouldBe` Just (outcome (DraftDone draftPr))

        it "takes a merged or closed PR on the branch for an old one, not the draft" $
            [ due g withPr {pr = Just (PullRequest draftPr over)} (runAt (knobs Balanced Normal <> map Took (take 5 happyPath)))
            | over <- [IsMerged, IsClosed]
            ]
                `shouldBe` [Nothing, Nothing]

        it "skips ready in POC, leaving the draft" $
            due g withPr (atReady Poc) `shouldBe` Just (outcome (ReadySkipped prUrl))

        it "skips ready in POC offline, by the draft the run recorded" $
            due g noFacts (atReady Poc) `shouldBe` Just (outcome (ReadySkipped (Url "u")))

        it "records ready once GitHub says the PR is ready" $
            due g withPr {pr = Just (PullRequest draftPr IsReady)} (atReady Balanced) `shouldBe` Just (outcome (ReadyDone prUrl))

    describe "the 10x's fan-out" $ do
        let t1 = plainTask "t1" []
            t2 = plainTask "t2" []
            heavy name = (plainTask name []) {heavy = True}
            asks = Question (QId (runId "c1") 1) Design (oneLine "which store?")
            fromChild = [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (AsksUp asks.qid), Asked (Asking asks (StateName "engineers") (ChildRun (runId "c1")))]
        it "spawns the first task a slot is free for" $
            next noFacts (tenXAt (t1 :| [t2]) [Spawned (childOf "c1" "t1")]) `shouldBe` Spawn (AgentRole "engineer") (Just (TaskId "t2"))
        it "spawns no second heavy task while one runs" $
            next noFacts (tenXAt (heavy "t1" :| [heavy "t2"]) [Spawned (childOf "c1" "t1")]) `shouldBe` AwaitChildren (TaskId "t1" :| [])
        it "waits on the children while a task's dependencies run" $
            next noFacts (tenXAt (t1 :| [plainTask "t2" ["t1"]]) [Spawned (childOf "c1" "t1")]) `shouldBe` AwaitChildren (TaskId "t1" :| [])
        it "spawns the next task once a spawn is recorded, never the same task twice" $
            map (next noFacts . tenXAt (t1 :| [t2])) [[Spawning (TaskId "t1")], [Spawning (TaskId "t1"), Spawning (TaskId "t2")]]
                `shouldBe` [Spawn (AgentRole "engineer") (Just (TaskId "t2")), AwaitChildren (TaskId "t1" :| [TaskId "t2"])]
        it "resumes the next child once a resume is recorded, never the same child twice" $ do
            let asks2 = Question (QId (runId "c2") 1) Design (oneLine "which queue?")
                both = fromChild <> [RuledOn asks.qid ruling, Spawned (childOf "c2" "t2"), HandedBack (runId "c2") (AsksUp asks2.qid), Asked (Asking asks2 (StateName "engineers") (ChildRun (runId "c2"))), RuledOn asks2.qid ruling]
            map (next noFacts . tenXAt (t1 :| [t2])) [both <> [Resumed (runId "c1")], both <> [Resumed (runId "c1"), Resumed (runId "c2")]]
                `shouldBe` [Resume (runId "c2") "with the answer to c2:1", AwaitChildren (TaskId "t1" :| [TaskId "t2"])]
        it "waits on CI no more once the child is resumed" $
            next noFacts (tenXAt (t1 :| []) [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (AwaitsCi (oneLine "https://pr/1")), Resumed (runId "c1")]) `shouldBe` AwaitChildren (TaskId "t1" :| [])
        it "triages a child's stop before a retry, and retries once it is asked" $ do
            let stop = Stop Blocked "no access"
                stopped = [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Ended stop)]
                triaged = Question (QId (runId "r7f2") 1) Stuck (oneLine "retry?")
            map (next noFacts . tenXAt (t1 :| [])) [stopped, stopped <> [Asked (Asking triaged (StateName "engineers") (ChildRun (runId "c1"))), RuledOn triaged.qid ruling]]
                `shouldBe` [TriageStop (runId "c1") stop, Spawn (AgentRole "engineer") (Just (TaskId "t1"))]
        it "waits on the user's answer to a stopped child's question before a retry" $ do
            let stuckOn = Question (QId (runId "r7f2") 1) Stuck (oneLine "retry?")
                forwarded = [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Ended (Stop Blocked "no access")), Asked (Asking stuckOn (StateName "engineers") (ChildRun (runId "c1"))), Forwarded stuckOn.qid TheUser]
            map (next noFacts . tenXAt (t1 :| [])) [forwarded, forwarded <> [Answered stuckOn.qid "retry" TheUser]]
                `shouldBe` [AwaitAnswer stuckOn, Spawn (AgentRole "engineer") (Just (TaskId "t1"))]
        it "waits on the merge loop at merge, and ends only once every task is merged or parked" $ do
            let inReview = [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "PR #1")), TaskMoved (TaskId "t1") (InReview prUrl), stepTook (FanDone FEngineers)]
            map (next noFacts . tenXAt (t1 :| [])) [inReview, inReview <> [TaskMoved (TaskId "t1") (Merged prUrl)]]
                `shouldBe` [AwaitMerge (TaskId "t1" :| []), Run "state record merge.done <url>"]
        it "resumes a ruled child while the user holds another child's question" $ do
            let asks2 = Question (QId (runId "c2") 1) Security (oneLine "token in env?")
                forwarded = fromChild <> [RuledOn asks.qid ruling, Spawned (childOf "c2" "t2"), HandedBack (runId "c2") (AsksUp asks2.qid), Asked (Asking asks2 (StateName "engineers") (ChildRun (runId "c2"))), Forwarded asks2.qid TheUser]
            map (next noFacts . tenXAt (t1 :| [t2])) [forwarded, forwarded <> [Resumed (runId "c1")]]
                `shouldBe` [Resume (runId "c1") "with the answer to c1:1", AwaitAnswer asks2]
        it "records a finished task's PR when the child's READY named none" $
            map (next noFacts . tenXAt (t1 :| [t2]) . ([Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "done"))] <>)) [[], [TaskMoved (TaskId "t1") (InReview prUrl)]]
                `shouldBe` [Run "state record task t1 review <url>", Spawn (AgentRole "engineer") (Just (TaskId "t2"))]
        it "parks a finished POC task's PR as a draft when the child's READY named none" $
            next noFacts (tenXAt ((plainTask "t1" []) {quality = Poc} :| []) [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "done"))])
                `shouldBe` Run "state record task t1 parked POC --pr <url>"
        it "states a child's question no more once it is answered" $
            filter ("task " `Text.isPrefixOf`) (factLines noFacts (tenXAt (t1 :| []) (fromChild <> [RuledOn asks.qid ruling])))
                `shouldBe` ["task t1: child c1 waits to resume, tries 1"]
        it "triages a child's question before anything else" $
            next noFacts (tenXAt (t1 :| [t2]) fromChild) `shouldBe` Triage asks
        it "resumes a child once its question is ruled on" $
            next noFacts (tenXAt (t1 :| []) (fromChild <> [RuledOn asks.qid ruling])) `shouldBe` Resume (runId "c1") "with the answer to c1:1"
        it "waits on CI a child handed back" $
            next noFacts (tenXAt (t1 :| []) [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (AwaitsCi (oneLine "https://pr/1"))]) `shouldBe` AwaitCi "https://pr/1"
        it "leaves the fan-out itself once every task is settled, and not before" $ do
            let finished = [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Finished (oneLine "PR #1"))]
            due tenXGraph noFacts (tenXAt (t1 :| [t2]) finished) `shouldBe` Nothing
            due tenXGraph noFacts (tenXAt (t1 :| [t2]) (finished <> [TaskMoved (TaskId "t2") (Parked "not needed" Nothing)])) `shouldBe` Just (outcome (FanDone FEngineers))
        it "states each task's child, PR and tries" $
            filter ("task " `Text.isPrefixOf`) (factLines noFacts (tenXAt (t1 :| [t2]) (fromChild <> [TaskMoved (TaskId "t1") (InCi prUrl)])))
                `shouldBe` ["task t1: child c1 asks c1:1, PR ci https://pr/1, tries 1", "task t2: not started, tries 0"]
        it "states a task's agent at work and its held wakes" $
            filter ("task " `Text.isPrefixOf`) (factLines noFacts (tenXAt (t1 :| []) (fromChild <> [RuledOn asks.qid ruling, Resumed (runId "c1"), Held (TaskId "t1") (Url "https://pr/1#c")])))
                `shouldBe` ["task t1: child c1 running, agent at work, tries 1, held https://pr/1#c"]

    describe "deliver" $ do
        it "spawns in the background only where the interface can" $
            map (\ops -> deliver start {interface = Set.fromList ops} (Spawn (AgentRole "implementer") Nothing)) [[], [Background]]
                `shouldBe` ["SPAWN implementer background: no", "SPAWN implementer background: yes"]

        it "names a basis in the triage line of a Security question only" $
            map (\kind -> deliver start (Triage (Question which.qid kind which.text))) [Design, Security]
                `shouldBe` [ "RUN state rule r7f2:1 --answer <a> --why <w> --cost <c> | state forward r7f2:1 - Design r7f2:1: which store?"
                           , "RUN state rule r7f2:1 --answer <a> --why <w> --cost <c> --basis <event-id>|obvious:<why> | state forward r7f2:1 - Security r7f2:1: which store?"
                           ]

        it "asks the user a forwarded question, or hands it back to a parent run" $
            map (`deliver` AwaitAnswer which) [start, child]
                `shouldBe` ["ASK Design r7f2:1: which store?", "HANDBACK NEEDS_DECISION Design r7f2:1: which store?"]

        it "names the task an engineer is spawned for" $
            deliver start {interface = Set.fromList [Background]} (Spawn (AgentRole "engineer") (Just (TaskId "t1"))) `shouldBe` "SPAWN engineer --task t1 background: yes"

        it "resumes a child, or waits on the children" $
            map (deliver start) [Resume (runId "c1") "with the answer to c1:1", AwaitChildren (TaskId "t1" :| [TaskId "t2"]), AwaitMerge (TaskId "t1" :| [])]
                `shouldBe` ["RESUME c1 with the answer to c1:1", "AWAIT children t1 t2", "AWAIT merge t1"]

        it "puts a child's stop to triage as a question from the child" $
            deliver start (TriageStop (runId "c1") (Stop Blocked "no access"))
                `shouldBe` "RUN state ask --kind <kind> --from c1 <question> - triage: BLOCKED no access"

        it "waits on CI itself only where the interface can" $
            map (`deliver` AwaitCi "u") [start {interface = Set.singleton Await}, start]
                `shouldBe` ["AWAIT ci u", "HANDBACK AWAIT ci u"]

        it "notifies at ready only where the interface can, so a child run leaves it to its parent" $ do
            let ready = advise steps noFacts (atReady Balanced)
            map (`deliverPrompt` ready) [start {interface = Set.singleton Notify}, child]
                `shouldBe` [ready.prompt <> " Then notify.", ready.prompt]
        it "ends as DONE for the user, READY for a parent run" $
            map (`deliver` Done (Just prUrl)) [start, child]
                `shouldBe` ["DONE https://pr/1", "HANDBACK READY https://pr/1"]

        it "stops for the user, or hands the stop back to a parent run" $
            map (`deliver` Stopped (Stop Fuel "review")) [start, child]
                `shouldBe` ["STOP fuel review", "HANDBACK BLOCKED out of fuel: review"]

    describe "ownAsk" $ do
        it "forwards a Design question to the user" $
            ownAsk atImplement Design (oneLine "which store?") `shouldBe` askedUp "ASK user" TheUser

        it "hands a Design question back to a parent run" $
            ownAsk (runUnder child (knobs Balanced Normal <> map Took (take 6 happyPath))) Design (oneLine "which store?")
                `shouldBe` askedUp "HANDBACK NEEDS_DECISION Design r7f2:1: which store?" (ParentRun parent)

        it "forwards a Normal task's Confirm to whoever started the run" $
            [ line
            | from <- [start, child]
            , let (_, _, line) = ownAsk (runUnder from (knobs Balanced Normal <> map Took (take 4 happyPath))) Confirm (oneLine "the plan holds?")
            ]
                `shouldBe` ["ASK user", "HANDBACK NEEDS_DECISION Confirm r7f2:1: the plan holds?"]

        it "leaves a Trivial task's Confirm to the run itself" $
            let (_, _, line) = ownAsk (runAt (knobs Balanced Trivial <> map Took (take 4 happyPath))) Confirm (oneLine "the plan holds?")
             in line `shouldBe` "ANSWER yourself"

        it "leaves a Pick question to the run itself" $
            ownAsk atImplement Pick (oneLine "which rows?")
                `shouldBe` (Question (QId run 1) Pick (oneLine "which rows?"), [Asked (Asking (Question (QId run 1) Pick (oneLine "which rows?")) implement Itself)], "ANSWER yourself")
  where
    noFacts = Facts Nothing Nothing
    withPr = noFacts {pr = Just (PullRequest draftPr IsDraft)}
    prUrl = Url "https://pr/1"
    draftPr = DraftPr prUrl (Branch "main") (Branch "b")
    parent = runId "p1"
    child = start {principal = ByRole (Parent parent "/p/events.jsonl" (TaskId "t1")), interface = Set.empty}
    which = Question (QId run 1) Design (oneLine "which store?")
    notMet = Picks Set.empty (Map.singleton (Requirement "R1") NotMet)
    ruling = Proposal (oneLine "confirmed") (oneLine "the plan holds") (oneLine "none") Nothing
    implement = StateName "implement"
    atImplement = runAt (knobs Balanced Normal <> map Took (take 6 happyPath))
    atConfirm = runAt (knobs Balanced Normal <> map Took (take 4 happyPath))
    atRefactor = runAt (knobs Balanced Normal <> map Took (take 7 happyPath))
    atReady quality = runAt (knobs quality Normal <> map Took (take 12 happyPath))
    atPick size rest = runAt (knobs Balanced size <> map Took (take 8 happyPath) <> [stepTook (ReviewRows sha)] <> rest)
    -- A Design question the run's own row forwards: asked, then forwarded at once.
    askedUp line above = (which, [Asked (Asking which implement Itself), Forwarded which.qid above], line)

knobs :: Quality -> Size -> [Event]
knobs quality size = [QualitySet quality, SizeSet size]

runs :: (Text -> Bool) -> Action -> Bool
runs holds = \case
    Run command -> holds command
    _ -> False

genFacts :: Gen Facts
genFacts = Facts <$> Gen.maybe (Gen.integral (Range.linear 0 300)) <*> Gen.maybe genPullRequest

genPullRequest :: Gen PullRequest
genPullRequest =
    PullRequest
        <$> (DraftPr . Url <$> genText <*> pure (Branch "main") <*> pure (Branch "b"))
        <*> Gen.element [IsDraft, IsReady, IsMerged, IsClosed]
