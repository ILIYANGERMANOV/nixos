module State.Flows.TenXSpec (spec) where

import Data.Either (isRight)
import State.Cap (StateName (..))
import State.FlowGen (skipsKept)
import State.Flows.TenX (tenX)
import State.Graph (graph)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Flows.TenX" $ do
    it "builds: no state has two edges on one event, no loop id is used twice" $
        graph tenX `shouldSatisfy` isRight

    {- The steps #351's Keep law names run inside each engineer, whose own spec
    holds them: here no mode may skip the fan-out that runs the engineers, nor
    the merge their PRs end in.
    -}
    it "no_mode_skips_kept_steps" $
        skipsKept (graph tenX) (map StateName ["engineers", "merge"]) `shouldBe` []
