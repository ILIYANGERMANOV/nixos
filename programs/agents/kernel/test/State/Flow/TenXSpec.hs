module State.Flow.TenXSpec (spec) where

import Data.Either (isRight)
import State.Category.Flow (Flow (..), Name, scoped)
import State.Category.FlowGen (skipsKept)
import State.Category.Graph (graph)
import State.Category.Step (StateName (..))
import State.Flow.TenX (tenX)
import State.Role (FlowName (EngineerFlow), RoleDef (..), role)
import State.Step.Fan (engineers)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Flow.TenX" $ do
    it "builds: no state has two edges on one event, no loop id is used twice" $
        graph tenX `shouldSatisfy` isRight

    {- The steps #351's Keep law names run inside each engineer, whose own spec
    holds them: here no level may skip the fan-out that runs the engineers, nor
    the merge their PRs end in.
    -}
    it "no_mode_skips_kept_steps" $
        skipsKept (graph tenX) (map StateName ["engineers", "merge"]) `shouldBe` []

    -- The graph draws the fan-out's body as a task's default flow; each child runs its own task's.
    it "draws the registry's engineer flow as its fan-out's body" $
        lookup engineers (parBodies tenX) `shouldBe` Just (show (role EngineerFlow).flow)

{- | Each fan-out's body, shown. Compared by 'show', not 'graph': 'graph'
draws a 'Par' as one state, and a 'Par' hides the types 'graph' needs of its
body.
-}
parBodies :: Flow i e o -> [(Name, String)]
parBodies = \case
    Do _ -> []
    Capped {} -> []
    f :> g -> parBodies f <> parBodies g
    Id -> []
    Loop _ body -> parBodies body
    Opt _ _ body -> parBodies body
    Par fan body -> (fan, show body) : parBodies body
    InL -> []
    InR -> []
    f :||| g -> parBodies f <> parBodies g
    Catch body -> parBodies body
    Scope scope body -> [(scoped scope fan, shown) | (fan, shown) <- parBodies body]
    Choice _ branches -> concatMap parBodies branches
