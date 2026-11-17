module State.RoleSpec (spec) where

import Data.Either (isRight)
import Data.Set qualified as Set
import State.Category.Graph (graph, placeName, places)
import State.Category.Step (StateName (..))
import State.Category.Ty (Ty (..))
import State.Flow.Library (agree)
import State.Role (AgentRole (..), FlowName (..), RoleDef (..), Rung (..), SomeFlow (..), flowOut, role, rungAt)
import State.Run.RunGen (flowGraph)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Role" $ do
    describe "rungAt" $ do
        it "climbs from the run's own rung outside any flow's scope" $
            map (rungAt TenXFlow . StateName) ["implement", "security/review", "out"] `shouldBe` [Orchestrator, Orchestrator, Orchestrator]

        it "climbs from the run's own rung at every state of the engineer, 10x and architect flows, as before scopes ran flows" $
            [(flowName, rungAt flowName (placeName place)) | flowName <- [minBound .. maxBound], place <- Set.toList (places (flowGraph flowName))]
                `shouldBe` [(flowName, rung) | (flowName, rung) <- [(EngineerFlow, Lead), (TenXFlow, Orchestrator), (ArchitectFlow, Lead)], _ <- Set.toList (places (flowGraph flowName))]

        it "climbs from the 10x's rung inside a scoped 10x, whatever flow the run follows" $
            rungAt EngineerFlow (StateName "10x/gather") `shouldBe` Orchestrator

        it "climbs from the engineer's rung inside a scoped engineer" $
            rungAt TenXFlow (StateName "engineer/implement") `shouldBe` Lead

        it "reads the innermost flow's scope, past scopes that run no flow" $
            map (rungAt EngineerFlow . StateName) ["engineer/10x/security/review", "10x/engineer/security/review"] `shouldBe` [Orchestrator, Lead]

    describe "RoleDef" $ do
        it "leads a flow that ends in a plan, not a PR" $ do
            let planner = RoleDef (AgentRole "planner") (SomeFlow agree) Lead
            flowOut planner.flow `shouldBe` Plan
            case planner.flow of
                SomeFlow flow -> graph flow `shouldSatisfy` isRight

        it "keeps the engineer's and the 10x's flows ending in a PR, the architect's in a ticket" $
            map (flowOut . (.flow) . role) [minBound .. maxBound] `shouldBe` [PR, PR, Ticket]
