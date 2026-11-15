module State.Flow.TenXSpec (spec) where

import Data.Either (isRight)
import State.Category.Flow (FanId (FEngineers), Flow (..))
import State.Category.FlowGen (skipsKept)
import State.Category.Graph (graph)
import State.Category.Step (StateName (..))
import State.Flow.TenX (tenX)
import State.Role (RoleDef (..), role)
import State.Run.Event (fanFlow)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Flow.TenX" $ do
    it "builds: no state has two edges on one event, no loop id is used twice" $
        graph tenX `shouldSatisfy` isRight

    {- The steps #351's Keep law names run inside each engineer, whose own spec
    holds them: here no mode may skip the fan-out that runs the engineers, nor
    the merge their PRs end in.
    -}
    it "no_mode_skips_kept_steps" $
        skipsKept (graph tenX) (map StateName ["engineers", "merge"]) `shouldBe` []

    -- The fan-out runs each task's child on the flow the registry names for it.
    it "runs the registry's engineer flow at its fan-out" $
        lookup FEngineers (parBodies tenX) `shouldBe` fmap (show . (.flow) . role) (fanFlow FEngineers)

{- | Each fan-out's body, shown: a 'Par' hides its body's types, so no two
bodies share one to compare by 'graph', which also draws a 'Par' as one state.
-}
parBodies :: Flow i e o -> [(FanId, String)]
parBodies = \case
    Do _ -> []
    f :> g -> parBodies f <> parBodies g
    Loop _ _ body -> parBodies body
    Opt _ body -> parBodies body
    Par fan body -> (fan, show body) : parBodies body
    InL -> []
    InR -> []
    f :||| g -> parBodies f <> parBodies g
