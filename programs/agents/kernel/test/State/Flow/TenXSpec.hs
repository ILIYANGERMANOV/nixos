module State.Flow.TenXSpec (spec) where

import Data.Either (isRight)
import State.Category.FlowGen (skipsKept)
import State.Category.Graph (graph)
import State.Category.Step (StateName (..))
import State.Flow.Engineer (engineer)
import State.Flow.TenX (tenX)
import State.Role (FlowName (EngineerFlow), RoleDef (..), role)
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

    -- The fan-out runs each task's child on the engineer flow the registry names.
    it "runs the registry's engineer flow at its fan-out" $
        graph engineer `shouldBe` graph (role EngineerFlow).flow
