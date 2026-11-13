module State.GraphSpec (spec) where

import Control.Monad (foldM)
import Data.Map.Strict qualified as Map
import Hedgehog (Gen, PropertyT, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Cap (EventName (..), OutcomeName (..), Outcomes (..), StateName (..), Step (..), outcomes)
import State.Flow (Flow (..), LoopId (..), OnEmpty (..), OptId (..))
import State.FlowGen (ctxKit, diffKit, genEndo, genExiting, genFlow, genWalk, genWalkTo)
import State.Graph (Clash (..), Edge (..), Node (..), OpenGraph (..), Place (..), graph)
import State.Path (step, ty)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Graph" $ do
    {- The law, read off the graph of @f :> g@ as a run sees it, not by
    gluing again: it holds both sides' edges and loops, a walk through @f@ to
    its end goes on into @g@, typed as the two in turn, and an exit of either
    side is the whole's exit.
    -}
    describe "graph_of_seq_is_glue_of_graphs" $ do
        it "keeps every edge and loop of both sides" . hedgehog $ do
            (left, right, whole) <- seqGraphs (genExiting diffKit) (genExiting diffKit)
            (Map.size whole.edges, Map.size whole.loops) === (Map.size left.edges + Map.size right.edges, Map.size left.loops + Map.size right.loops)

        it "walks the first side to its end, then the second, when neither exits" . hedgehog $ do
            (left, right, whole) <- seqGraphs (genEndo ctxKit) (genEndo ctxKit)
            walkF <- forAll (genWalk left)
            walkG <- forAll (genWalk right)
            (endOf whole (walkF <> walkG), ty whole (walkF <> walkG)) === (Just Out, (<>) <$> ty left walkF <*> ty right walkG)

        it "walks the first side to its end, then the second to its end or exit" . hedgehog $ do
            (left, right, whole) <- seqGraphs (genExiting diffKit) (genExiting diffKit)
            walkF <- forAll (genWalk left)
            port <- forAll (Gen.element [Out, Exit])
            walkG <- forAll (genWalkTo port right)
            (endOf whole (walkF <> walkG), ty whole (walkF <> walkG)) === (Just port, (<>) <$> ty left walkF <*> ty right walkG)

        it "takes an exit of the first side as the whole's exit" . hedgehog $ do
            (left, _, whole) <- seqGraphs (genExiting diffKit) (genExiting diffKit)
            walkF <- forAll (genWalkTo Exit left)
            (endOf whole walkF, ty whole walkF) === (Just Exit, ty left walkF)

    {- A 'Map' keyed by (state, event) holds one target per pair, so the law
    can only break by an edge silently merged into another's key: the graph
    must keep every arrow of the term.
    -}
    it "graph_has_one_target_per_state_event" . hedgehog $ do
        (flow, g) <- forAll (Gen.mapMaybe (\flow -> either (const Nothing) (Just . (flow,)) (graph flow)) genFlow)
        Map.size g.edges === arrows flow

    it "refuses a loop id used twice: their rounds would mix" $
        graph (Loop LReview ExitOut (Do Review :> Loop LReview ExitOut (Do Pick :> Do Fix)))
            `shouldBe` Left (SameLoop LReview)

    it "refuses two skips of one state: a log could not say which was skipped" $
        graph (Opt ORes (Opt OSimp (Do Research)))
            `shouldBe` Left (SameEvent (Place [] (StateName "research")) (EventName (StateName "research") (OutcomeName "skipped")))

-- | The graphs of two terms and of their series, over terms that build: 'Clash' has its own cases.
seqGraphs :: Gen (Flow a e1 b) -> Gen (Flow b e2 c) -> PropertyT IO (OpenGraph, OpenGraph, OpenGraph)
seqGraphs genF genG = forAll (Gen.mapMaybe builds ((,) <$> genF <*> genG))
  where
    builds (f, g) = case (graph f, graph g, graph (f :> g)) of
        (Right left, Right right, Right whole) -> Just (left, right, whole)
        _ -> Nothing

-- | Where the events walk from the in port.
endOf :: OpenGraph -> [EventName] -> Maybe Node
endOf g = foldM next (At g.inPort)
  where
    next node event = case node of
        At place -> (.to) <$> step g place event
        Out -> Nothing
        Exit -> Nothing

-- | One per outcome of each step, one per skip, and a fan-out's three events.
arrows :: Flow i e o -> Int
arrows = \case
    Do s -> case outcomes s of
        Continues _ -> 1
        ExitsOr _ _ -> 2
    f :> g -> arrows f + arrows g
    Loop _ _ body -> arrows body
    Opt _ body -> 1 + arrows body
    Par _ _ -> 3
