module State.AdviceSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Advice
import State.Ask (Above (..), Kind (..), Proposal (..), QId (..), Question (..))
import State.Event hiding (Stopped)
import State.EventGen (genStart, genText, oneLine, run, runId, start)
import State.Mode (Quality (..), Size (..))
import State.RunGen (commit, g, genAccepted, happyPath, loadSteps, runAt, runUnder, sha)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Advice" $ do
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

    describe "pick" $ do
        it "offers pick.loop while a review round is left" $
            next noFacts (atPick Normal [])
                `shouldSatisfy` runs ("state record pick.loop" `Text.isPrefixOf`)

        it "offers Trivial's one review pick.loop only with a Not met" $
            next noFacts (atPick Trivial [])
                `shouldSatisfy` runs (\command -> "state record pick.final" `Text.isPrefixOf` command && "only with a not-met verdict" `Text.isInfixOf` command)

        it "offers only pick.final once no review round is left" $
            next noFacts (atPick Trivial [Took (PickLoop notMet), Took (FixDone commit), Took (ReviewRows sha)])
                `shouldSatisfy` runs (\command -> "state record pick.final" `Text.isPrefixOf` command && not ("pick.loop" `Text.isInfixOf` command))

    describe "confirm" $ do
        it "asks Confirm at confirm" $
            next noFacts atConfirm `shouldSatisfy` \case
                Ask Confirm _ -> True
                _ -> False

        it "asks Confirm once, then advises its outcome" $ do
            let (question, asked, _) = ownAsk atConfirm Confirm (oneLine "the plan holds?")
                ruled = runAt (knobs Balanced Normal <> map Took (take 5 happyPath) <> asked <> [RuledOn question.qid ruling])
            next noFacts ruled `shouldBe` Run "state record confirm.confirmed | state record confirm.adjusted"

    describe "due" $ do
        it "skips research in Trivial" $
            due g noFacts (runAt (knobs Balanced Trivial)) `shouldBe` Just ResearchSkipped

        it "skips the refactor at or below its changed lines" $
            due g noFacts {changedLines = Just 100} atRefactor
                `shouldBe` Just (RefactorSkipped "100 changed lines, at or below 100")

        it "runs the refactor above its changed lines, or when they are unknown" $
            map (\changed -> due g noFacts {changedLines = changed} atRefactor) [Just 101, Nothing] `shouldBe` [Nothing, Nothing]

        it "records the draft PR GitHub already has" $
            due g withPr {pr = Just (PullRequest draftPr IsDraft)} (runAt (knobs Balanced Normal <> map Took (take 6 happyPath)))
                `shouldBe` Just (DraftDone draftPr)

        it "takes a merged or closed PR on the branch for an old one, not the draft" $
            [ due g withPr {pr = Just (PullRequest draftPr over)} (runAt (knobs Balanced Normal <> map Took (take 6 happyPath)))
            | over <- [IsMerged, IsClosed]
            ]
                `shouldBe` [Nothing, Nothing]

        it "skips ready in POC, leaving the draft" $
            due g withPr (atReady Poc) `shouldBe` Just (ReadySkipped prUrl)

        it "skips ready in POC offline, by the draft the run recorded" $
            due g noFacts (atReady Poc) `shouldBe` Just (ReadySkipped (Url "u"))

        it "records ready once GitHub says the PR is ready" $
            due g withPr {pr = Just (PullRequest draftPr IsReady)} (atReady Balanced) `shouldBe` Just (ReadyDone prUrl)

    describe "deliver" $ do
        it "spawns in the background only where the interface can" $
            map (\ops -> deliver start {interface = Set.fromList ops} (Spawn (AgentRole "implementer"))) [[], [Background]]
                `shouldBe` ["SPAWN implementer background: no", "SPAWN implementer background: yes"]

        it "asks the user a forwarded question, or hands it back to a parent run" $
            map (`deliver` AwaitAnswer which) [start, child]
                `shouldBe` ["ASK Design r7f2:1: which store?", "HANDBACK NEEDS_DECISION Design r7f2:1: which store?"]

        it "waits on CI itself only where the interface can" $
            map (`deliver` AwaitCi "u") [start {interface = Set.singleton Await}, start]
                `shouldBe` ["AWAIT ci u", "HANDBACK AWAIT ci u"]

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
            ownAsk (runUnder child (knobs Balanced Normal <> map Took (take 7 happyPath))) Design (oneLine "which store?")
                `shouldBe` askedUp "HANDBACK NEEDS_DECISION Design r7f2:1: which store?" (ParentRun parent)

        it "leaves a Pick question to the run itself" $
            ownAsk atImplement Pick (oneLine "which rows?")
                `shouldBe` (Question (QId run 1) Pick (oneLine "which rows?"), [Asked (Asking (Question (QId run 1) Pick (oneLine "which rows?")) implement Itself)], "ANSWER yourself")
  where
    noFacts = Facts Nothing Nothing
    withPr = noFacts {pr = Just (PullRequest draftPr IsDraft)}
    prUrl = Url "https://pr/1"
    draftPr = DraftPr prUrl (Branch "main") (Branch "b")
    parent = runId "p1"
    child = start {principal = ByRole parent "/p/events.jsonl", interface = Set.empty}
    which = Question (QId run 1) Design (oneLine "which store?")
    notMet = Picks Set.empty (Map.singleton (Requirement "R1") NotMet)
    ruling = Proposal (oneLine "confirmed") (oneLine "the plan holds") (oneLine "none") Nothing
    implement = StateName "implement"
    atImplement = runAt (knobs Balanced Normal <> map Took (take 7 happyPath))
    atConfirm = runAt (knobs Balanced Normal <> map Took (take 5 happyPath))
    atRefactor = runAt (knobs Balanced Normal <> map Took (take 8 happyPath))
    atReady quality = runAt (knobs quality Normal <> map Took (take 13 happyPath))
    atPick size rest = runAt (knobs Balanced size <> map Took (take 9 happyPath) <> [Took (ReviewRows sha)] <> rest)
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
