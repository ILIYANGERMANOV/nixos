module State.Category.PathSpec (spec) where

import Data.Foldable (find)
import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Hedgehog (Gen, assert, evalMaybe, failure, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (Flow (..))
import State.Category.FlowGen (composes, genFlow, pathTo)
import State.Category.Fuel (SkipWhen (..), always)
import State.Category.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..), graph, places)
import State.Category.Path (step, ty)
import State.Category.Step (EventName (..), OutcomeEdge (..), OutcomeName (..), StateName (..))
import State.Category.Ty (TyOf (..), TyVal)
import State.Flow.Library (opt)
import State.Step.Build (Sing (..))
import State.Step.Review (Sing (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Category.Path" $ do
    it "skipped_maps_to_identity" . hedgehog $ do
        (g, (place, event, edge)) <- forAll genSkip
        before <- evalMaybe (pathTo g (At g.inPort) (At place))
        after <- evalMaybe (pathTo g edge.to Out)

        case edge.arrow of
            Along along -> along.cod === along.dom
            Stay -> failure
        path <- evalMaybe (ty g (before <> [event] <> after))
        assert (composes path)
        ends path === Just (Ctx, PR)

    it "takes a skip to where running the skipped step goes" $ do
        let built = graph (opt "refactor" (always Skippable) (Do Refactor) :> Do Review)
            from state event = do
                g <- either (const Nothing) Just built
                at <- find ((== StateName state) . (.name)) (places g)
                edge <- step g at (EventName (StateName state) (OutcomeName event))
                Just edge.to
        from "skip_refactor" "skip" `shouldBe` from "refactor" "done"
        from "skip_refactor" "skip" `shouldNotBe` Nothing

-- | A built flow and one of its skip edges.
genSkip :: Gen (OpenGraph, (Place, EventName, Edge Node))
genSkip = do
    (g, skips) <- Gen.mapMaybe withSkips genFlow
    skip <- Gen.element skips
    pure (g, skip)
  where
    withSkips flow = do
        g <- either (const Nothing) Just (graph flow)
        skips <- nonEmpty [(place, event, edge) | ((place, event), edge) <- Map.toList g.edges, event.outcome == OutcomeName "skip"]
        Just (g, skips)

ends :: [OutcomeEdge] -> Maybe (TyVal, TyVal)
ends path = do
    first <- listToMaybe path
    final <- listToMaybe (reverse path)
    pure (first.dom, final.cod)
