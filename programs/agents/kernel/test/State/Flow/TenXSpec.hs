module State.Flow.TenXSpec (spec) where

import Data.Either (isRight)
import State.Category.Flow (Flow (..), Group (..), Name, branchesWith, scoped)
import State.Category.FlowGen (skipsKept)
import State.Category.Graph (graph)
import State.Category.Step (StateName (..))
import State.Flow.TenX (tenX)
import State.Role (FlowName (EngineerFlow), RoleDef (..), SomeFlow (..), role)
import State.Step.Fan (engineers)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Flow.TenX" $ do
    it "builds: no state has two edges on one event, no loop id is used twice" $
        graph tenX `shouldSatisfy` isRight

    {- The steps #351's Keep law names run inside each engineer, whose own spec
    holds them: here no level may skip the await of the engineers, nor
    the merge their PRs end in.
    -}
    it "no_mode_skips_kept_steps" $
        skipsKept (graph tenX) (map StateName ["engineers", "merge"]) `shouldBe` []

    -- The term holds the fork's body as a task's default flow; each child runs its own task's.
    it "forks the registry's engineer flow as each engineer's body" $
        lookup engineers (parBodies tenX) `shouldBe` Just (case (role EngineerFlow).flow of SomeFlow flow -> show flow)

{- | Each fork's body, by its group, shown. Compared by 'show', not
'graph': 'graph' draws a 'Fork' as one state, and a 'Fork' hides the types
'graph' needs of its body.
-}
parBodies :: Flow i e o -> [(Name, String)]
parBodies = \case
    Do _ -> []
    Capped {} -> []
    f :> g -> parBodies f <> parBodies g
    Id -> []
    Into -> []
    Loop _ body -> parBodies body
    Case branches -> concat (branchesWith parBodies branches)
    Exit -> []
    Each body -> parBodies body
    Fork (Group group _) body -> (group, show body) : parBodies body
    Await _ -> []
    Catch body -> parBodies body
    Scope scope body -> [(scoped scope fan, shown) | (fan, shown) <- parBodies body]
