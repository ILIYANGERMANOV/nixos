module State.Category.PathSpec (spec) where

import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Hedgehog (Gen, assert, evalMaybe, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (Flow (..), OptId (..))
import State.Category.FlowGen (composes, genFlow, pathTo)
import State.Category.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place, graph)
import State.Category.Path (step, ty)
import State.Category.Step (EventName (..), OutcomeEdge (..), OutcomeName (..), StateName (..))
import State.Category.Ty (Ty (..))
import State.Step.Gather (Sing (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Category.Path" $ do
    it "skipped_maps_to_identity" . hedgehog $ do
        (g, (place, event, edge)) <- forAll genSkip
        before <- evalMaybe (pathTo g (At g.inPort) (At place))
        after <- evalMaybe (pathTo g edge.to Out)

        ty g (before <> [event]) === ty g before
        path <- evalMaybe (ty g (before <> [event] <> after))
        assert (composes path)
        ends path === Just (Ctx, PR)

    it "takes a skip to where running the skipped step goes" $ do
        let built = graph (Opt ORes (Do Research) :> Do Interview)
            from event = do
                g <- either (const Nothing) Just built
                edge <- step g g.inPort event
                Just edge.to
        from (EventName (StateName "research") (OutcomeName "skipped")) `shouldBe` from (EventName (StateName "research") (OutcomeName "done"))
        from (EventName (StateName "research") (OutcomeName "skipped")) `shouldNotBe` Nothing

-- | A built flow and one of its skip edges.
genSkip :: Gen (OpenGraph, (Place, EventName, Edge))
genSkip = do
    (g, skips) <- Gen.mapMaybe withSkips genFlow
    skip <- Gen.element skips
    pure (g, skip)
  where
    withSkips flow = do
        g <- either (const Nothing) Just (graph flow)
        skips <- nonEmpty [(place, event, edge) | ((place, event), edge@Edge {arrow = Skip _}) <- Map.toList g.edges]
        Just (g, skips)

ends :: [OutcomeEdge] -> Maybe (Ty, Ty)
ends path = do
    first <- listToMaybe path
    final <- listToMaybe (reverse path)
    pure (first.dom, final.cod)
