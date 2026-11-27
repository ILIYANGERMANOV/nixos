-- | A gap's hand-back line, and its status as Appendix B's gap table moves it.
module State.Run.GapSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust, isNothing, listToMaybe)
import Hedgehog (Gen, cover, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Artifact (Uri)
import State.Category.Flow (AgentRole (..))
import State.Run.Event (Event (..), Stop (..), StopReason (..))
import State.Run.EventGen (bareGap, logOf, oneLine, started, uri)
import State.Run.Fold (Refusal (..), RunState (..), replay)
import State.Run.Gap
import State.Run.RunGen (g)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Gap" $ do
    describe "a hand-back's Gap: line" $ do
        it "reads a kind, a severity and the text" $
            parseGapLine " kernel blocker the fold drops a line"
                `shouldBe` Just (WellFormed Kernel Blocker (oneLine "the fold drops a line"))

        it "keeps a line whose words are no kind and severity whole" $
            parseGapLine "core blocker a slip"
                `shouldBe` Just (Malformed (oneLine "core blocker a slip"))

        it "keeps a line with a kind and severity but no text whole" $
            parseGapLine "kernel blocker"
                `shouldBe` Just (Malformed (oneLine "kernel blocker"))

        it "reads a blank line as no gap" $
            parseGapLine "  " `shouldBe` Nothing

        it "logs a malformed line as other and slowdown, its whole text kept" $
            lineGap (GapArea "fix") fixer (Malformed (oneLine "core blocker a slip"))
                `shouldBe` Gap Other Slowdown (GapArea "fix") (oneLine "core blocker a slip") fixer []

        it
            "logs a well-formed line with its kind and severity, met where the hand-back closes"
            $ lineGap (GapArea "fix") fixer (WellFormed Tool Papercut (oneLine "slow grep"))
                `shouldBe` Gap Tool Papercut (GapArea "fix") (oneLine "slow grep") fixer []

    describe "the gap table" $ do
        it "moves an open gap along every edge" $
            map (transition Open) [Propose pr1, Close (Fixed pr1), Close wontFix]
                `shouldBe` [To (FixProposed pr1), To (Closed (Fixed pr1)), To (Closed wontFix)]

        it
            "moves a proposed gap to a new PR or closed, and takes the same PR again as a no-op"
            $ map
                (transition (FixProposed pr1))
                [Propose pr2, Propose pr1, Close (Fixed pr2), Close wontFix]
                `shouldBe` [To (FixProposed pr2), Again, To (Closed (Fixed pr2)), To (Closed wontFix)]

        it "refuses every move on a fixed or won't-fix gap" $
            [ transition (Closed closure) move
            | closure <- [Fixed pr1, wontFix]
            , move <- moves
            ]
                `shouldBe` [Shut closure | closure <- [Fixed pr1, wontFix], _ <- moves]

    describe "the fold" $ do
        it "keeps a closed gap closed, refusing any later move gap_closed" . hedgehog $ do
            closure <- forAll genClosure
            move <- forAll genMove
            cover 20 "fixed" (isFixed closure)
            cover 20 "won't fix" (not (isFixed closure))
            cover 20 "then proposed" (isPropose move)
            cover 20 "then closed" (not (isPropose move))
            replayed [GapMoved 1 (Close closure), GapMoved 1 move]
                === Left (GapClosed 1 closure)

        it "gives a gap the status its last accepted event set" . hedgehog $ do
            proposals <- forAll (Gen.list (Range.linear 0 5) (Gen.element [pr1, pr2]))
            closing <- forAll (Gen.frequency [(1, pure Nothing), (1, Just <$> genClosure)])
            cover 20 "proposed again with the same PR" (repeats proposals)
            cover 20 "closed last" (isJust closing)
            cover 3 "still open" (null proposals && isNothing closing)
            let events =
                    map (GapMoved 1 . Propose) proposals
                        <> [GapMoved 1 (Close c) | Just c <- [closing]]
                expected = case closing of
                    Just c -> Closed c
                    Nothing -> maybe Open FixProposed (lastOf proposals)
            (fmap (.status) . lookup 1 . (.gaps) <$> replayed events)
                === Right (Just expected)

        it "refuses a move on a seq that is no gap unknown_gap" . hedgehog $ do
            n <- forAll (Gen.integral (Range.linear 0 (20 :: Natural)))
            move <- forAll genMove
            cover 5 "the started line" (n == 0)
            cover 50 "no line at all" (n > 1)
            if n == 1
                then pure ()
                else replayed [GapMoved n move] === Left (UnknownGap n)

        it "takes a move on a run that stopped" $
            fmap
                (fmap (.status) . lookup 1 . (.gaps))
                ( replay
                    g
                    ( logOf
                        ( started
                            :| [Gapped gap, Stopped (Stop Blocked "no access"), GapMoved 1 (Close (Fixed pr1))]
                        )
                    )
                )
                `shouldBe` Right (Just (Closed (Fixed pr1)))
  where
    fixer = AgentRole "fixer"
    gap = bareGap "the hook drops a line"
    -- A run with a gap at seq 1, then these events.
    replayed events = replay g (logOf (started :| Gapped gap : events))
    moves = [Propose pr1, Close (Fixed pr2), Close wontFix]
    repeats proposals = or (zipWith (==) proposals (drop 1 proposals))
    lastOf = listToMaybe . reverse
    isFixed = \case
        Fixed _ -> True
        WontFix _ -> False
    isPropose = \case
        Propose _ -> True
        Close _ -> False

pr1, pr2 :: Uri
pr1 = uri "https://github.com/o/r/pull/1"
pr2 = uri "https://github.com/o/r/pull/2"

wontFix :: Closure
wontFix = WontFix (oneLine "out of scope")

genClosure :: Gen Closure
genClosure = Gen.choice [Fixed <$> Gen.element [pr1, pr2], pure wontFix]

genMove :: Gen GapMove
genMove = Gen.choice [Propose <$> Gen.element [pr1, pr2], Close <$> genClosure]
