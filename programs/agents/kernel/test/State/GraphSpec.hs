module State.GraphSpec (spec) where

import Hedgehog (Gen, PropertyT, evalEither, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Cap (EventName (..), Step (..))
import State.Flow (Flow (..), LoopId (..), OnEmpty (..), OptId (..))
import State.FlowGen (ctxKit, diffKit, genEndo, genExiting, genWalk)
import State.Graph (Clash (..), Place (..), glue, graph)
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
