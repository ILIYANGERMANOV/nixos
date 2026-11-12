module State.GraphSpec (spec) where

import Data.Map.Strict qualified as Map
import Hedgehog (Gen, PropertyT, evalEither, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Cap (EventName (..), Outcomes (..), Step (..), outcomes)
import State.Flow (Flow (..), LoopId (..), OnEmpty (..), OptId (..))
import State.FlowGen (ctxKit, diffKit, genEndo, genExiting, genFlow, genWalk)
import State.Graph (Clash (..), OpenGraph (..), Place (..), glue, graph)
import State.Path (ty)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Graph" $ do
    describe "graph_of_seq_is_glue_of_graphs" $ do
        it "with no exit" . hedgehog $
            seqIsGlue (genEndo ctxKit) (genEndo ctxKit)

        it "with an exit on both sides, which become one" . hedgehog $
            seqIsGlue (genExiting diffKit) (genExiting diffKit)

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
            `shouldBe` Left (SameEvent (Place [] "research") (EventName "research" "skipped"))

{- | The graph of @f :> g@ is the two graphs glued, so a walk through @f@ and
then one through @g@ is a walk through the whole, typed as the two in turn.
Over terms that build: 'Clash' has its own cases above.
-}
seqIsGlue :: Gen (Flow a e1 b) -> Gen (Flow b e2 c) -> PropertyT IO ()
seqIsGlue genF genG = do
    (f, g, left, right) <- forAll (Gen.mapMaybe builds ((,) <$> genF <*> genG))
    graph (f :> g) === glue left right
    whole <- evalEither (graph (f :> g))
    walkF <- forAll (genWalk left)
    walkG <- forAll (genWalk right)
    ty whole (walkF <> walkG) === ((<>) <$> ty left walkF <*> ty right walkG)
  where
    builds (f, g) = case (graph f, graph g, graph (f :> g)) of
        (Right left, Right right, Right _) -> Just (f, g, left, right)
        _ -> Nothing

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
