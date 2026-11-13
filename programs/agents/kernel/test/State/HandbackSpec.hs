module State.HandbackSpec (spec) where

import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, forAll, tripping)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Ask (Kind (..), QId (..), Question (..))
import State.Event (AgentRole (..), Asker (..), Asking (..), Commit (..), Event (Asked, HandedBack, Spawned, TaskMoved, Took), Outcome (..), Picks (..), Said (..), Sha (..), StateName (..), Task (..), TaskId (..), TaskState (..), Url (..))
import State.Event qualified as Event
import State.EventGen (genOneLine, genQuestion, genRunId, oneLine, run, runId)
import State.Handback
import State.Mode (Area (..), Quality (..))
import State.RunGen (childOf, happyPath, loadSteps, plainTask, runAt, sha, tenXAt)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Handback" $ do
    it "handback_round_trips" . hedgehog $ do
        handback <- forAll genHandback
        tripping handback renderHandback parseHandback

    it "reads each token from line 1" $
        for_ tokens $ \(first, token) ->
            (.token) <$> parseHandback first `shouldBe` Right token

    it "reads line 1 pasted with the HANDBACK delivery prefix as the bare token" $
        for_ tokens $ \(first, token) ->
            (.token) <$> parseHandback ("HANDBACK " <> first) `shouldBe` Right token

    it "reads the last of a repeated trailer, and the areas touched" $
        parseHandback "READY\n\nReviewed head: 1111111\nReviewed head: 9f8e7d6\nTouches: auth, data-model"
            `shouldBe` Right (blank (Just (Ready (oneLine "")))) {reviewedHead = Just (Sha "9f8e7d6"), touches = Just (Set.fromList [Auth, DataModel])}

    it "reads a GREW line below NEEDS_DECISION as the decision's" $
        (.token) <$> parseHandback "NEEDS_DECISION stuck: two stores\nGREW three modules"
            `shouldBe` Right (Just (NeedsDecision (StuckOn (oneLine "two stores")) (Just (oneLine "three modules"))))

    it "refuses a GREW line below any other line 1" $
        parseHandback "READY built\nGREW three modules" `shouldSatisfy` either (Text.isInfixOf "NEEDS_DECISION only") (const False)

    it "hands a re-plan stop up as a plan found wrong, not as a question asked (law Re-plan)" $
        stopLine (Event.Stop Event.Replan "no such table") `shouldBe` "NEEDS_DECISION plan wrong: no such table"

    it "refuses a Touches line naming no area" $
        parseHandback "READY\nTouches: auth, the parser" `shouldSatisfy` either (Text.isInfixOf "the parser") (const False)

    typing

typing :: Spec
typing = describe "typeHandback" $ do
    steps <- runIO loadSteps
    let typed at role = typeHandback steps at (Just sha) (AgentRole role) . parsed

    it "types an implementer's READY as implement.done at the head, with its areas" $
        typed atImplement "implementer" "READY built\nTouches: auth"
            `shouldBe` Right (Typed [Took (ImplementDone (Commit sha (Set.singleton Auth)))] Nothing)

    it "reads an implementer's hand-back with no Touches line as touching every area" $
        typed atImplement "implementer" "READY built"
            `shouldBe` Right (Typed [Took (ImplementDone (Commit sha (Set.fromList [minBound .. maxBound])))] Nothing)

    it "reads a fixer's hand-back with no Touches line as touching none" $
        typed atFix "fixer" "READY fixed"
            `shouldBe` Right (Typed [Took (FixDone (Commit sha Set.empty))] Nothing)

    it "refuses a READY from a role that does not run the step" $
        typed atImplement "fixer" "READY fixed" `shouldSatisfy` isLeft

    it "types a review-lead's report as review.rows at its reviewed head" $
        typed atReview "review-lead" "| # | Severity | What |\n\nReviewed head: 9f8e7d6"
            `shouldBe` Right (Typed [Took (ReviewRows (Sha "9f8e7d6"))] Nothing)

    it "refuses a review-lead's report with no reviewed head" $
        typed atReview "review-lead" "| # | Severity | What |" `shouldSatisfy` isLeft

    it "refuses a line 1 with no token from any other role" $
        typed atImplement "implementer" "built it" `shouldSatisfy` isLeft

    it "asks a stuck question under the run's next own id" $
        typed atImplement "implementer" "NEEDS_DECISION stuck: the same test fails"
            `shouldBe` Right (Typed [Asked (Asking (Question (QId run 1) Stuck (oneLine "the same test fails")) implement (Subagent (AgentRole "implementer")))] Nothing)

    it "asks a typed question as the child run that sent it" $
        typed atImplement "engineer" "NEEDS_DECISION Design c1:2: which store?\nRun: c1"
            `shouldBe` Right (Typed [Asked (Asking (Question (QId (runId "c1") 2) Design (oneLine "which store?")) implement (ChildRun (runId "c1")))] Nothing)

    it "leaves BLOCKED to the run to triage, recording it as the worker's" $
        typed atImplement "implementer" "BLOCKED no access"
            `shouldBe` Right (Typed [Event.WorkerHandedBack (AgentRole "implementer") (oneLine "BLOCKED no access")] (Just (oneLine "BLOCKED no access")))

    it "records a GREW below a stuck question as grew beside the question" $
        typed atImplement "implementer" "NEEDS_DECISION stuck: two stores\nGREW three modules"
            `shouldBe` Right (Typed [Asked (Asking (Question (QId run 1) Stuck (oneLine "two stores")) implement (Subagent (AgentRole "implementer"))), Event.Grew "three modules"] Nothing)

    it "records GREW as grew" $
        typed atImplement "implementer" "GREW three modules"
            `shouldBe` Right (Typed [Event.Grew "three modules"] Nothing)

    describe "a child's hand-back at the fan-out" $ do
        let fromChild = typed atFanOut "engineer"
            c1 = runId "c1"
        it "refuses one that does not name its run" $
            fromChild "READY https://pr/1" `shouldSatisfy` either (Text.isInfixOf "add Run: <run id> as line 2") (const False)
        it "records READY as the child finished, the PR it names in review" $
            fromChild "READY https://pr/1\nRun: c1" `shouldBe` Right (Typed [HandedBack c1 (Finished (oneLine "https://pr/1")), TaskMoved (TaskId "t1") (InReview (Url "https://pr/1"))] Nothing)
        it "records a POC task's READY as parked, its PR a draft" $
            typed (tenXAt ((plainTask "t1" []) {quality = Poc} :| []) [Spawned (childOf "c1" "t1")]) "engineer" "READY https://pr/1\nRun: c1"
                `shouldBe` Right (Typed [HandedBack c1 (Finished (oneLine "https://pr/1")), TaskMoved (TaskId "t1") (Parked "POC" (Just (Url "https://pr/1")))] Nothing)
        it "records only the finish of a READY that names no PR" $
            fromChild "READY done\nRun: c1" `shouldBe` Right (Typed [HandedBack c1 (Finished (oneLine "done"))] Nothing)
        it "records a question as asked up by the child, which joins this run's pending, its GREW aside" $
            fromChild "NEEDS_DECISION Design c1:2: which store?\nGREW two modules\nRun: c1"
                `shouldBe` Right (Typed [HandedBack c1 (AsksUp (QId c1 2)), Asked (Asking (Question (QId c1 2) Design (oneLine "which store?")) engineers (ChildRun c1))] Nothing)
        it "records AWAIT ci as the child awaiting CI" $
            fromChild "AWAIT ci https://pr/1\nRun: c1" `shouldBe` Right (Typed [HandedBack c1 (AwaitsCi (oneLine "https://pr/1"))] Nothing)
        it "records a stop as the child ended, for this run to triage" $
            map fromChild ["BLOCKED no access\nRun: c1", "NEEDS_DECISION plan wrong: no such table\nRun: c1"]
                `shouldBe` [ Right (Typed [HandedBack c1 (Ended (Event.Stop Event.Blocked "no access"))] (Just (oneLine "BLOCKED no access")))
                           , Right (Typed [HandedBack c1 (Ended (Event.Stop Event.Replan "no such table"))] (Just (oneLine "NEEDS_DECISION plan wrong: no such table")))
                           ]
        it "reads a child's fuel stop as the log spells it" $
            fromChild "BLOCKED out of fuel: three rounds\nRun: c1"
                `shouldBe` Right (Typed [HandedBack c1 (Ended (Event.Stop Event.Fuel "three rounds"))] (Just (oneLine "BLOCKED out of fuel: three rounds")))
        it "refuses a question the child did not ask in its own run" $
            fromChild "NEEDS_DECISION stuck: same rows\nRun: c1" `shouldSatisfy` isLeft
  where
    atImplement = runAt (map Took (take 7 happyPath))
    atReview = runAt (map Took (take 9 happyPath))
    atFix = runAt (map Took (take 9 happyPath <> [ReviewRows sha, PickLoop (Picks Set.empty Map.empty)]))
    atFanOut = tenXAt (plainTask "t1" [] :| []) [Spawned (childOf "c1" "t1")]
    implement = StateName "implement"
    engineers = StateName "engineers"
    isLeft = either (const True) (const False)

tokens :: [(Text, Maybe Token)]
tokens =
    [ ("READY done in abc", Just (Ready (oneLine "done in abc")))
    , ("NEEDS_DECISION Design r7f2:3: which store?", Just (NeedsDecision (Asks (Question (QId run 3) Design (oneLine "which store?"))) Nothing))
    , ("NEEDS_DECISION stuck: same rows twice", Just (NeedsDecision (StuckOn (oneLine "same rows twice")) Nothing))
    , ("NEEDS_DECISION plan wrong: no such table", Just (NeedsDecision (PlanWrong (oneLine "no such table")) Nothing))
    , ("NEEDS_DECISION should I?", Just (NeedsDecision (Untyped (oneLine "should I?")) Nothing))
    , ("AWAIT ci https://pr/1", Just (Await Ci (oneLine "https://pr/1")))
    , ("GREW three modules", Just (Grew (oneLine "three modules")))
    , ("BLOCKED no access", Just (Blocked (oneLine "no access")))
    , ("FAILED tests red", Just (Failed (oneLine "tests red")))
    , ("| # | Severity | What |", Nothing)
    ]

parsed :: Text -> Handback
parsed = either (error . Text.unpack) id . parseHandback

blank :: Maybe Token -> Handback
blank token = Handback token Nothing Nothing Nothing Nothing

genHandback :: Gen Handback
genHandback =
    Handback
        <$> Gen.maybe genToken
        <*> Gen.maybe genRunId
        <*> Gen.maybe genSha
        <*> Gen.maybe genSha
        <*> Gen.maybe (Set.fromList <$> Gen.subsequence [minBound .. maxBound])

genToken :: Gen Token
genToken =
    Gen.choice
        [ Ready <$> genOneLine
        , NeedsDecision <$> genNeed <*> Gen.maybe genOneLine
        , Await Ci <$> genOneLine
        , Grew <$> genOneLine
        , Blocked <$> genOneLine
        , Failed <$> genOneLine
        ]

genNeed :: Gen Need
genNeed =
    Gen.choice
        [ Asks <$> genQuestion
        , StuckOn <$> genOneLine
        , PlanWrong <$> genOneLine
        , -- Words no kind and no label start, as a reader's free question reads.
          Untyped . oneLine . ("which " <>) <$> Gen.text (Range.linear 0 20) Gen.alphaNum
        ]

genSha :: Gen Sha
genSha = Sha <$> Gen.text (Range.linear 7 40) Gen.hexit
