module State.Protocol.HandbackSpec (spec) where

import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, forAll, tripping)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Flow (scopePath)
import State.Category.Fuel (Area (..), Fuel (Balanced))
import State.Protocol.Handback
import State.Run.Ask (Kind (..), QId (..), Question (..))
import State.Run.Event (
    AgentId (..),
    AgentRole (..),
    Asker (..),
    Asking (..),
    Commit (..),
    Event (Asked, HandedBack, Spawned, TaskMoved, Took),
    Picks (..),
    Said (..),
    Sha (..),
    StateName (..),
    TaskId (..),
    TaskState (..),
    Url (..),
    stepTook,
    tookIn,
 )
import State.Run.Event qualified as Event
import State.Run.EventGen (
    fuelSet,
    genOneLine,
    genQuestion,
    genRunId,
    oneLine,
    run,
    runId,
 )
import State.Run.RunGen (
    childOf,
    g,
    happyPath,
    loadSteps,
    plainTask,
    runAt,
    sha,
    tenXAt,
 )
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome)
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..))
import State.Step.Review (Outcome (..))
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Protocol.Handback" $ do
    it "handback_round_trips" . hedgehog $ do
        handback <- forAll genHandback
        tripping handback renderHandback parseHandback

    it "reads each token from line 1" $
        for_ tokens $ \(first, token) ->
            (.token) <$> parseHandback first `shouldBe` Right token

    it "refuses an AWAIT on anything but CI or a merge" $
        parseHandback "AWAIT deploy prod"
            `shouldBe` Left (Why "AWAIT deploy: only ci or merge is awaited")

    it "reads line 1 pasted with the HANDBACK delivery prefix as the bare token" $
        for_ tokens $ \(first, token) ->
            (.token) <$> parseHandback ("HANDBACK " <> first) `shouldBe` Right token

    it "reads the last of a repeated trailer, and the areas touched" $
        parseHandback
            "READY\n\nReviewed head: 1111111\nReviewed head: 9f8e7d6\nTouches: auth, data-model"
            `shouldBe` Right
                (blank (Just (Ready (oneLine ""))))
                    { reviewedHead = Just (Sha "9f8e7d6")
                    , touches = Just (Set.fromList [Auth, DataModel])
                    }

    it
        "hands a re-plan stop up as a plan found wrong, not as a question asked (law Re-plan)"
        $ stopLine (Event.Stop Event.Replan "no such table")
            `shouldBe` "NEEDS_DECISION plan wrong: no such table"

    it "refuses a Touches line naming no area" $
        parseHandback "READY\nTouches: auth, the parser"
            `shouldBe` Left (NoArea "the parser")

    typing

typing :: Spec
typing = describe "typeHandback" $ do
    steps <- runIO loadSteps
    let typed at role = typeHandback steps g at (Just sha) (AgentRole role) Nothing . parsed

    it "types an implementer's READY as implement.done at the head, with its areas" $
        typed atImplement "implementer" "READY built\nTouches: auth"
            `shouldBe` Right
                (Typed [stepTook (ImplementDone (Commit sha (Set.singleton Auth)))] Nothing)

    it
        "reads an implementer's hand-back with no Touches line as touching every area"
        $ typed atImplement "implementer" "READY built"
            `shouldBe` Right
                ( Typed
                    [stepTook (ImplementDone (Commit sha (Set.fromList [minBound .. maxBound])))]
                    Nothing
                )

    it "reads a fixer's hand-back with no Touches line as touching none" $
        typed atFix "fixer" "READY fixed"
            `shouldBe` Right (Typed [stepTook (FixDone (Commit sha Set.empty))] Nothing)

    it
        "says a worker logged at work returned, by its id or else its role, and no other"
        $ do
            let fixing =
                    runAt
                        ( fuelSet Balanced
                            : take 13 happyPath
                                <> map
                                    (Took mempty)
                                    [outcome (ReviewRows sha), outcome (PickLoop (Picks Set.empty Map.empty))]
                                <> [Event.WorkerSpawned (AgentRole "fixer") (AgentId "a1")]
                        )
                returns agent =
                    drop 1 . (.events)
                        <$> typeHandback
                            steps
                            g
                            fixing
                            (Just sha)
                            (AgentRole "fixer")
                            agent
                            (parsed "READY fixed")
            map returns [Just (AgentId "a1"), Nothing, Just (AgentId "a2")]
                `shouldBe` [ Right [Event.WorkerReturned (AgentRole "fixer") (Just (AgentId "a1"))]
                           , Right [Event.WorkerReturned (AgentRole "fixer") Nothing]
                           , Right []
                           ]

    it "refuses a READY from a role that does not run the step" $
        typed atImplement "fixer" "READY fixed" `shouldSatisfy` isLeft

    it "types a review-lead's report as review.rows at its reviewed head" $
        typed atReview "review-lead" "| # | Severity | What |\n\nReviewed head: 9f8e7d6"
            `shouldBe` Right (Typed [stepTook (ReviewRows (Sha "9f8e7d6"))] Nothing)

    it "refuses a review-lead's report with no reviewed head" $
        typed atReview "review-lead" "| # | Severity | What |" `shouldSatisfy` isLeft

    it "refuses a line 1 with no token from any other role" $
        typed atImplement "implementer" "built it" `shouldBe` Left NoToken

    it
        "closes a researcher's child at the gather on its report, which opens with no token"
        $ typed atGather "researcher" "The Index, ranked\n1. src/State.hs:12"
            `shouldBe` Right (Typed [tookIn (scopePath "gather") ResearchHandedBack] Nothing)

    it
        "records simplify_plan.done on a researcher's report, which opens with no token"
        $ typed atSimplifyPlan "researcher" "# t5 plan (simplify proposal)\n## Goals"
            `shouldBe` Right (Typed [stepTook SimplifyPlanDone] Nothing)

    it "asks a stuck question under the run's next own id" $
        typed atImplement "implementer" "NEEDS_DECISION stuck: the same test fails"
            `shouldBe` Right
                ( Typed
                    [ Asked
                        ( Asking
                            (Question (QId run 1) Stuck (oneLine "the same test fails"))
                            implement
                            (Subagent (AgentRole "implementer"))
                        )
                    ]
                    Nothing
                )

    it "asks a typed question as the child run that sent it" $
        typed atImplement "engineer" "NEEDS_DECISION Design c1:2: which store?\nRun: c1"
            `shouldBe` Right
                ( Typed
                    [ Asked
                        ( Asking
                            (Question (QId (runId "c1") 2) Design (oneLine "which store?"))
                            implement
                            (ChildRun (runId "c1"))
                        )
                    ]
                    Nothing
                )

    it "leaves BLOCKED to the run to triage, recording it as the worker's" $
        typed atImplement "implementer" "BLOCKED no access"
            `shouldBe` Right
                ( Typed
                    [Event.WorkerHandedBack (AgentRole "implementer") (oneLine "BLOCKED no access")]
                    (Just (oneLine "BLOCKED no access"))
                )

    it "records a stuck question as asked by the worker, where it is" $
        typed atImplement "implementer" "NEEDS_DECISION stuck: two stores"
            `shouldBe` Right
                ( Typed
                    [ Asked
                        ( Asking
                            (Question (QId run 1) Stuck (oneLine "two stores"))
                            implement
                            (Subagent (AgentRole "implementer"))
                        )
                    ]
                    Nothing
                )

    describe "a child's hand-back at the fan-out" $ do
        let fromChild = typed atFanOut "engineer"
            c1 = runId "c1"
        it "refuses one that does not name its run" $
            fromChild "READY https://pr/1"
                `shouldSatisfy` either
                    (Text.isInfixOf "add Run: <run id> as line 2" . refusalText)
                    (const False)
        it "records READY as the child finished, the PR it names in review" $
            fromChild "READY https://pr/1\nRun: c1"
                `shouldBe` Right
                    ( Typed
                        [ HandedBack c1 (Finished (oneLine "https://pr/1"))
                        , TaskMoved (TaskId "t1") (InReview (Url "https://pr/1"))
                        ]
                        Nothing
                    )
        it "records only the finish of a READY that names no PR" $
            fromChild "READY done\nRun: c1"
                `shouldBe` Right (Typed [HandedBack c1 (Finished (oneLine "done"))] Nothing)
        it "records a question as asked up by the child, which joins this run's pending" $
            fromChild "NEEDS_DECISION Design c1:2: which store?\nRun: c1"
                `shouldBe` Right
                    ( Typed
                        [ HandedBack c1 (AsksUp (QId c1 2))
                        , Asked
                            ( Asking
                                (Question (QId c1 2) Design (oneLine "which store?"))
                                engineers
                                (ChildRun c1)
                            )
                        ]
                        Nothing
                    )
        it "records AWAIT ci or merge as the child awaiting it" $
            map
                fromChild
                [ "AWAIT ci https://pr/1\nRun: c1"
                , "AWAIT merge https://pr/1 https://pr/2\nRun: c1"
                ]
                `shouldBe` [ Right (Typed [HandedBack c1 (Awaits Ci (oneLine "https://pr/1"))] Nothing)
                           , Right
                                ( Typed
                                    [HandedBack c1 (Awaits Merge (oneLine "https://pr/1 https://pr/2"))]
                                    Nothing
                                )
                           ]
        it "records a stop as the child ended, for this run to triage" $
            map
                fromChild
                [ "BLOCKED no access\nRun: c1"
                , "NEEDS_DECISION plan wrong: no such table\nRun: c1"
                ]
                `shouldBe` [ Right
                                ( Typed
                                    [HandedBack c1 (Ended (Event.Stop Event.Blocked "no access"))]
                                    (Just (oneLine "BLOCKED no access"))
                                )
                           , Right
                                ( Typed
                                    [HandedBack c1 (Ended (Event.Stop Event.Replan "no such table"))]
                                    (Just (oneLine "NEEDS_DECISION plan wrong: no such table"))
                                )
                           ]
        it "reads a child's rounds stop as the log spells it" $
            fromChild "BLOCKED out of rounds: three rounds\nRun: c1"
                `shouldBe` Right
                    ( Typed
                        [HandedBack c1 (Ended (Event.Stop Event.OutOfRounds "three rounds"))]
                        (Just (oneLine "BLOCKED out of rounds: three rounds"))
                    )
        it "refuses a question the child did not ask in its own run" $
            fromChild "NEEDS_DECISION stuck: same rows\nRun: c1" `shouldSatisfy` isLeft
  where
    atGather = runAt (fuelSet Balanced : take 2 happyPath)
    atSimplifyPlan = runAt (fuelSet Balanced : take 7 happyPath)
    atImplement = runAt (fuelSet Balanced : take 10 happyPath)
    atReview = runAt (fuelSet Balanced : take 13 happyPath)
    atFix =
        runAt
            ( fuelSet Balanced
                : take 13 happyPath
                    <> map
                        (Took mempty)
                        [outcome (ReviewRows sha), outcome (PickLoop (Picks Set.empty Map.empty))]
            )
    atFanOut = tenXAt (plainTask "t1" [] :| []) [Spawned (childOf "c1" "t1")]
    implement = StateName "implement"
    engineers = StateName "engineers"
    isLeft = either (const True) (const False)

tokens :: [(Text, Maybe Token)]
tokens =
    [ ("READY done in abc", Just (Ready (oneLine "done in abc")))
    , ("READY: done", Just (Ready (oneLine "done")))
    ,
        ( "NEEDS_DECISION Design r7f2:3: which store?"
        , Just
            (NeedsDecision (Asks (Question (QId run 3) Design (oneLine "which store?"))))
        )
    ,
        ( "NEEDS_DECISION stuck: same rows twice"
        , Just (NeedsDecision (StuckOn (oneLine "same rows twice")))
        )
    ,
        ( "NEEDS_DECISION plan wrong: no such table"
        , Just (NeedsDecision (PlanWrong (oneLine "no such table")))
        )
    ,
        ( "NEEDS_DECISION should I?"
        , Just (NeedsDecision (Untyped (oneLine "should I?")))
        )
    , ("AWAIT ci https://pr/1", Just (Await Ci (oneLine "https://pr/1")))
    ,
        ( "AWAIT merge https://pr/1 https://pr/2"
        , Just (Await Merge (oneLine "https://pr/1 https://pr/2"))
        )
    , ("BLOCKED no access", Just (Blocked (oneLine "no access")))
    , ("FAILED tests red", Just (Failed (oneLine "tests red")))
    , ("| # | Severity | What |", Nothing)
    ]

parsed :: Text -> Handback
parsed = either (error . Text.unpack . refusalText) id . parseHandback

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
        , NeedsDecision <$> genNeed
        , Await <$> Gen.enumBounded <*> genOneLine
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
