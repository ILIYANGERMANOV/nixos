module State.FoldSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Hedgehog (Gen, assert, cover, evalEither, evalMaybe, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Cap (EventName)
import State.Event
import State.EventGen (genOutcomeNamed, hookLine, line, logOf, outcomeNames, runId, started)
import State.Flow (LoopId (..), OptId (..))
import State.FlowGen (composes, genWalk)
import State.Flows.Engineer (engineer)
import State.Fold
import State.Graph (Arrow (..), Edge (..), LoopAt (..), Node (..), OpenGraph (..), Place (..), graph)
import State.Mode (Cfg (..), Mode (..), Quality (..), Size (..), cfg)
import State.Path (ty)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Fold" $ do
    it "names every edge of the engineer flow by exactly one kind of outcome" $
        outcomeNames `shouldBe` Set.fromList [name | ((_, name), edge) <- Map.toList g.edges, edge.arrow /= Stay]

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

    it "refuses a review round past the fuel" $
        replay g (logOf (started :| QualitySet Balanced : SizeSet Trivial : toReview <> reviewRound [] <> [Took (FixDone commit)]))
            `shouldBe` Left (OutOfFuel LReview 1)

    it "gives one more round after a Not met at the fuel, never two" $ do
        let unmet = Picks [] [Verdict (Requirement "R1") NotMet]
            twice = toReview <> roundWith unmet <> [Took (FixDone commit)] <> roundWith unmet
        (.at) <$> replay g (logOf (started :| SizeSet Trivial : twice)) `shouldSatisfy` either (const False) (/= Out)
        replay g (logOf (started :| SizeSet Trivial : twice <> [Took (FixDone commit)])) `shouldBe` Left (OutOfFuel LReview 1)

    it "stuck_after_two_same_rounds" . hedgehog $ do
        rows <- forAll (Gen.list (Range.linear 1 6) (Gen.subsequence ["A", "B", "C"]))
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
  where
    note = Note "no edge" "state next"
    stop = Stop Blocked "why"

g :: OpenGraph
g = either (error . show) id (graph engineer)

research :: Place
research = g.inPort

ofRun :: RunId -> Envelope -> Envelope
ofRun other (Envelope source n ts _ sha' session event) = Envelope source n ts other sha' session event

placeName :: Node -> Maybe StateName
placeName = \case
    At place -> Just place.name
    Out -> Nothing
    Exit -> Nothing

sha :: Sha
sha = Sha "abc123"

commit :: Commit
commit = Commit sha Set.empty

happyPath :: [Outcome]
happyPath =
    [ResearchDone 3, InterviewEnough, PlanDone "plan.md", SimplifyPlanDone, AlternativeDone, ConfirmConfirmed]
        <> [DraftDone (DraftPr (Url "u") (Branch "main") (Branch "b")), ImplementDone commit, RefactorDone sha, ReviewClean sha]
        <> [DescribeDone sha, SimplifyPrDone sha, AwaitCiGreen sha, ReadyDone (Url "u")]

-- | From the start to the first review.
toReview :: [Event]
toReview = map Took (take 9 happyPath)

-- | From the start to the first CI result.
toCi :: [Event]
toCi = map Took (take 9 happyPath <> [ReviewClean sha, DescribeDone sha, SimplifyPrDone sha])

reviewRound :: [Label] -> [Event]
reviewRound rows = roundWith (Picks rows [])

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

{- | Any mode, then up to 300 tries at an event on an edge out of where the
run is, keeping those the fold accepts. Edges that stay inside every loop are
likelier, so loops run out of fuel.
-}
genAccepted :: Gen [Event]
genAccepted = do
    knobs <- genKnobs
    steps <- Gen.int (Range.linear 0 300)
    first <- either (fail . show) pure (replay g (logOf (started :| knobs)))
    (knobs <>) <$> go steps first (fromIntegral (length knobs) + 1)
  where
    go :: Int -> RunState -> Natural -> Gen [Event]
    go 0 _ _ = pure []
    go k state n = case state.at of
        At place -> do
            name <- Gen.frequency [(if stays place edge then 5 else 1, pure name) | ((from, name), edge) <- Map.toList g.edges, from == place]
            outcome <- outcomeOf name
            case append g state (line n (Took outcome)) of
                Right (Appended next) -> (Took outcome :) <$> go (k - 1) next (n + 1)
                Right AlreadyLogged -> go (k - 1) state n
                Left _ -> go (k - 1) state n
        Out -> pure []
        Exit -> pure []
    stays place edge = case edge.to of
        At to -> all (\loop -> not (Set.member place loop.body) || Set.member to loop.body) (Map.elems g.loops)
        Out -> False
        Exit -> False

genKnobs :: Gen [Event]
genKnobs = (\quality size -> [QualitySet quality, SizeSet size]) <$> Gen.enumBounded <*> Gen.enumBounded

outcomeOf :: EventName -> Gen Outcome
outcomeOf name = fromMaybe Gen.discard (genOutcomeNamed name)
