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
    Event (Asked, Gapped, HandedBack, Spawned, TaskMoved, Took),
    Picks (..),
    Said (..),
    Sha (..),
    StateName (..),
    TaskState (..),
    Url (..),
    stepTook,
    tookIn,
 )
import State.Run.Event qualified as Event
import State.Run.EventGen (
    fuelSet,
    gapText,
    genOneLine,
    genQuestion,
    genRunId,
    oneLine,
    run,
    runId,
 )
import State.Run.Gap (
    Gap (..),
    GapArea (..),
    GapKind (Process, Tool),
    GapLine (..),
    Severity (Blocker, Papercut),
    gapTextText,
 )
import State.Run.RunGen (
    childOf,
    g,
    happyPath,
    loadSteps,
    plainTask,
    refTo,
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

    it "reads every Gap: line below line 1, list items and indented ones too" $
        (.gaps)
            <$> parseHandback
                "READY done\nGap: tool papercut slow grep\n- Gap: process blocker no runner\n  * Gap: odd words\n"
            `shouldBe` Right
                [ WellFormed Tool Papercut (gapText "slow grep")
                , WellFormed Process Blocker (gapText "no runner")
                , Malformed (gapText "odd words")
                ]

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
    -- The id of the line the hand-back's first event takes.
    let next = QId run 7
        typed at role message =
            typeHandback
                steps
                g
                at
                (Just sha)
                next
                (AgentRole role)
                Nothing
                message
                (parsed message)

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
                            : take 16 happyPath
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
                            next
                            (AgentRole "fixer")
                            agent
                            "READY fixed"
                            (parsed "READY fixed")
            map returns [Just (AgentId "a1"), Nothing, Just (AgentId "a2")]
                `shouldBe` [ Right [Event.WorkerReturned (AgentRole "fixer") (Just (AgentId "a1"))]
                           , Right [Event.WorkerReturned (AgentRole "fixer") Nothing]
                           , Right []
                           ]

    it
        "ends the oldest open span of the role by the hand-back's token, with the hand-back in full"
        $ do
            let fixing =
                    runAt
                        ( fuelSet Balanced
                            : take 16 happyPath
                                <> map
                                    (Took mempty)
                                    [outcome (ReviewRows sha), outcome (PickLoop (Picks Set.empty Map.empty))]
                                <> [ Event.SpanStarted
                                        ( Event.SpanStart
                                            (AgentRole "fixer")
                                            (Event.Harness "claude-code")
                                            "fix"
                                            Nothing
                                            Nothing
                                        )
                                   ]
                        )
                ending message =
                    (\result -> [end | Event.SpanEnded _ end _ <- result.events])
                        <$> typeHandback
                            steps
                            g
                            fixing
                            (Just sha)
                            next
                            (AgentRole "fixer")
                            Nothing
                            message
                            (parsed message)
            map ending ["READY fixed", "BLOCKED no access\nmore"]
                `shouldBe` [ Right [Event.WithHandback Event.ReadyWord "READY fixed"]
                           , Right [Event.WithHandback Event.BlockedWord "BLOCKED no access\nmore"]
                           ]

    it "ends a span by a tokenless report, a review-lead's table, as ready" $
        handbackEnding Nothing "| # | Severity |"
            `shouldBe` Event.WithHandback Event.ReadyWord "| # | Severity |"

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
        "records each refine pass done on its runner's findings, which open with no token"
        $ [ typed (runAt (fuelSet Balanced : take n happyPath)) role findings
          | (n, role) <- [(7, "researcher"), (8, "researcher"), (9, "reviewer")]
          ]
            `shouldBe` [ Right (Typed [stepTook SimplifyPlanDone] Nothing)
                       , Right (Typed [stepTook StandardsPlanDone] Nothing)
                       , Right (Typed [stepTook AlignPlanDone] Nothing)
                       ]

    it "refuses a refine pass's findings from a role that does not run it" $
        typed (runAt (fuelSet Balanced : take 9 happyPath)) "researcher" findings
            `shouldSatisfy` isLeft

    it "asks a stuck question under the id of the line that asks it" $
        typed atImplement "implementer" "NEEDS_DECISION stuck: the same test fails"
            `shouldBe` Right
                ( Typed
                    [ Asked
                        ( Asking
                            (Question (QId run 7) Stuck (oneLine "the same test fails"))
                            implement
                            (Subagent (AgentRole "implementer"))
                        )
                    ]
                    Nothing
                )

    it
        "asks a forked worker's stuck question under its line's id, after the line closing its child"
        $ fmap
            (\typed' -> [asking.question.qid | Asked asking <- typed'.events])
            (typed atGather "researcher" "NEEDS_DECISION stuck: two sources disagree")
            `shouldBe` Right [QId run 8]

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
                            (Question (QId run 7) Stuck (oneLine "two stores"))
                            implement
                            (Subagent (AgentRole "implementer"))
                        )
                    ]
                    Nothing
                )

    it
        "keeps a question's qid when its hand-back names gaps, each met at the step it closes"
        $ fmap
            ( \typed' ->
                ( [asking.question.qid | Asked asking <- typed'.events]
                , [gap.area | Gapped gap <- typed'.events]
                )
            )
            ( typed
                atImplement
                "implementer"
                "NEEDS_DECISION stuck: two stores\nGap: tool papercut slow grep\nGap: odd words"
            )
            `shouldBe` Right ([QId run 7], replicate 2 (GapArea (oneLine "implement")))

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
                        [ HandedBack c1 (Just (refTo "t1")) (Finished (oneLine "https://pr/1"))
                        , TaskMoved (refTo "t1") (InReview (Url "https://pr/1"))
                        ]
                        Nothing
                    )
        it "records only the finish of a READY that names no PR" $
            fromChild "READY done\nRun: c1"
                `shouldBe` Right
                    (Typed [HandedBack c1 (Just (refTo "t1")) (Finished (oneLine "done"))] Nothing)
        it "records a question as asked up by the child, which joins this run's pending" $
            fromChild "NEEDS_DECISION Design c1:2: which store?\nRun: c1"
                `shouldBe` Right
                    ( Typed
                        [ HandedBack c1 (Just (refTo "t1")) (AsksUp (QId c1 2))
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
                `shouldBe` [ Right
                                ( Typed
                                    [HandedBack c1 (Just (refTo "t1")) (Awaits Ci (oneLine "https://pr/1"))]
                                    Nothing
                                )
                           , Right
                                ( Typed
                                    [ HandedBack
                                        c1
                                        (Just (refTo "t1"))
                                        (Awaits Merge (oneLine "https://pr/1 https://pr/2"))
                                    ]
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
                                    [ HandedBack c1 (Just (refTo "t1")) (Ended (Event.Stop Event.Blocked "no access"))
                                    ]
                                    (Just (oneLine "BLOCKED no access"))
                                )
                           , Right
                                ( Typed
                                    [ HandedBack
                                        c1
                                        (Just (refTo "t1"))
                                        (Ended (Event.Stop Event.Replan "no such table"))
                                    ]
                                    (Just (oneLine "NEEDS_DECISION plan wrong: no such table"))
                                )
                           ]
        it "reads a child's rounds stop as the log spells it" $
            fromChild "BLOCKED out of rounds: three rounds\nRun: c1"
                `shouldBe` Right
                    ( Typed
                        [ HandedBack
                            c1
                            (Just (refTo "t1"))
                            (Ended (Event.Stop Event.OutOfRounds "three rounds"))
                        ]
                        (Just (oneLine "BLOCKED out of rounds: three rounds"))
                    )
        it "refuses a question the child did not ask in its own run" $
            fromChild "NEEDS_DECISION stuck: same rows\nRun: c1" `shouldSatisfy` isLeft
  where
    atGather = runAt (fuelSet Balanced : take 2 happyPath)
    findings = "| Concern | Finding | Change | Source | Confidence |"
    atImplement = runAt (fuelSet Balanced : take 13 happyPath)
    atReview = runAt (fuelSet Balanced : take 16 happyPath)
    atFix =
        runAt
            ( fuelSet Balanced
                : take 16 happyPath
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
blank token = Handback token Nothing Nothing Nothing Nothing []

genHandback :: Gen Handback
genHandback =
    Handback
        <$> Gen.maybe genToken
        <*> Gen.maybe genRunId
        <*> Gen.maybe genSha
        <*> Gen.maybe genSha
        <*> Gen.maybe (Set.fromList <$> Gen.subsequence [minBound .. maxBound])
        <*> Gen.list (Range.linear 0 3) genGapLine

-- | A @Gap:@ line of either form: a malformed one's first word is no gap kind.
genGapLine :: Gen GapLine
genGapLine =
    Gen.choice
        [ WellFormed <$> Gen.enumBounded <*> Gen.enumBounded <*> words'
        , Malformed . gapText . ("about " <>) . gapTextText <$> words'
        ]
  where
    words' =
        gapText . Text.unwords
            <$> Gen.list (Range.linear 1 4) (Gen.text (Range.linear 1 8) Gen.alphaNum)

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
