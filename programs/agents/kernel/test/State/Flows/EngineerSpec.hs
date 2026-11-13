module State.Flows.EngineerSpec (spec) where

import Data.Either (isRight)
import State.Cap (StateName (..))
import State.FlowGen (bypasses)
import State.Flows.Engineer (engineer)
import State.Graph (graph)
import State.Mode (Mode, modes)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Flows.Engineer" $ do
    it "builds: no state has two edges on one event, no loop id is used twice" $
        graph engineer `shouldSatisfy` isRight

    {- The steps #351's Keep law names that this flow runs: @review@ holds the
    security review and the blockers, @describe@ is the final fixer. Fact
    research is an answer to an ask, not a state (PR 3).
    -}
    it "no_mode_skips_kept_steps" $
        [(mode, kept) | mode <- modes, kept <- map StateName ["review", "describe"], skips mode kept]
            `shouldBe` []

skips :: Mode -> StateName -> Bool
skips mode kept = either (const True) (\g -> bypasses mode g kept) (graph engineer)
