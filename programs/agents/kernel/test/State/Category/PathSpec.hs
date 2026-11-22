module State.Category.PathSpec (spec) where

import Data.Foldable (find)
import Data.List (isPrefixOf)
import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Hedgehog (Gen, assert, evalMaybe, failure, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Flow (Flow (..))
import State.Category.FlowGen (composes, genFlow, genWalk, graphOf, pathTo)
import State.Category.Fuel (SkipWhen (..), always)
import State.Category.Graph (
    Arrow (..),
    Edge (..),
    Node (..),
    OpenGraph (..),
    Place (..),
    graph,
    places,
 )
import State.Category.Path (step, ty)
import State.Category.Step (
    EventName (..),
    OutcomeEdge (..),
    OutcomeName (..),
    StateName (..),
 )
import State.Category.Ty (TyOf (..), TyVal)
import State.Flow.Library (skippable)
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

    {- ty walks from the in port, so ty (p ++ q) = ty p ; ty q does not
    even typecheck: q starts mid-flow. What holds is a map of walks to paths
    that keeps the empty walk and prefixes.
    -}
    it "ty_maps_the_empty_walk_to_the_empty_path" . hedgehog $ do
        g <- forAll genGraph
        ty g [] === Just []

    it "ty_maps_a_prefix_of_a_walk_to_a_prefix_of_its_path" . hedgehog $ do
        g <- forAll genGraph
        walk <- forAll (genWalk g)
        n <- forAll (Gen.int (Range.linear 0 (length walk)))
        whole <- evalMaybe (ty g walk)
        front <- evalMaybe (ty g (take n walk))
        assert (front `isPrefixOf` whole)

    it "takes a skip to where running the skipped step goes" $ do
        let built = graph (skippable Refactor (always Skippable) :> Do Review)
            from state event = do
                g <- either (const Nothing) Just built
                at <- find ((== StateName state) . (.name)) (places g)
                edge <- step g at (EventName (StateName state) (OutcomeName event))
                Just edge.to
        from "skip_refactor" "skip" `shouldBe` from "refactor" "done"
        from "skip_refactor" "skip" `shouldNotBe` Nothing

-- | The graph of a generated flow that builds.
genGraph :: Gen OpenGraph
genGraph = Gen.mapMaybe graphOf genFlow

-- | A built flow and one of its skip edges.
genSkip :: Gen (OpenGraph, (Place, EventName, Edge Node))
genSkip = do
    (g, skips) <- Gen.mapMaybe withSkips genFlow
    skip <- Gen.element skips
    pure (g, skip)
  where
    withSkips flow = do
        g <- graphOf flow
        skips <-
            nonEmpty
                [ (place, event, edge)
                | ((place, event), edge) <- Map.toList g.edges
                , event.outcome == OutcomeName "skip"
                ]
        Just (g, skips)

ends :: [OutcomeEdge] -> Maybe (TyVal, TyVal)
ends path = do
    first <- listToMaybe path
    final <- listToMaybe (reverse path)
    pure (first.dom, final.cod)
