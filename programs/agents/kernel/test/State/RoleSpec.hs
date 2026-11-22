module State.RoleSpec (spec) where

import Data.Either (isRight)
import Data.Set qualified as Set
import Data.Type.Equality ((:~:) (..))
import State.Category.Effect (Eff (..), Handler (..))
import State.Category.Flow (Effects, Flow (Handle), Shape (HandleS), scopeNames)
import State.Category.Graph (Place (..), graph, placeName, places)
import State.Category.Step (StateName (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Architect (ArchitectS)
import State.Flow.Chief (ChiefS)
import State.Flow.Engineer (EngineerS)
import State.Flow.Library (ParallelS, agree)
import State.Flow.TenX (TenXS)
import State.Role (AgentRole (..), FlowName (..), RoleDef (..), Rung (..), SomeFlow (..), flowOut, role, rungAt)
import State.Run.RunGen (chiefGraph, flowGraph)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Role" $ do
    describe "rungAt" $ do
        it "climbs from the run's own rung outside any flow's scope" $
            map (rungAt TenXFlow . StateName) ["implement", "security/review", "out"] `shouldBe` [Orchestrator, Orchestrator, Orchestrator]

        it "climbs from the run's own rung at every state of the engineer, 10x and architect flows, as before scopes ran flows" $
            [(flowName, rungAt flowName (placeName place)) | flowName <- [EngineerFlow, TenXFlow, ArchitectFlow], place <- Set.toList (places (flowGraph flowName))]
                `shouldBe` [(flowName, rung) | (flowName, rung) <- [(EngineerFlow, Lead), (TenXFlow, Orchestrator), (ArchitectFlow, Lead)], _ <- Set.toList (places (flowGraph flowName))]

        it "climbs from the Orchestrator's rung at every state of the chief's 10x branch, from the Lead's at every other" $
            [(scope, rungAt ChiefFlow (placeName place)) | place <- Set.toList (places chiefGraph), let scope = take 1 (scopeNames place.scope)]
                `shouldBe` [(scope, if scope == ["10x"] then Orchestrator else Lead) | place <- Set.toList (places chiefGraph), let scope = take 1 (scopeNames place.scope)]

        it "climbs from the 10x's rung inside a scoped 10x, whatever flow the run follows" $
            rungAt EngineerFlow (StateName "10x/gather") `shouldBe` Orchestrator

        it "climbs from the engineer's rung inside a scoped engineer" $
            rungAt TenXFlow (StateName "engineer/implement") `shouldBe` Lead

        it "reads the innermost flow's scope, past scopes that run no flow" $
            map (rungAt EngineerFlow . StateName) ["engineer/10x/security/review", "10x/engineer/security/review"] `shouldBe` [Orchestrator, Lead]

    describe "RoleDef" $ do
        it "leads a flow that ends in a plan, not a PR" $ do
            let planner = RoleDef (AgentRole "planner") (SomeFlow (Handle AskHandler (Handle PickHandler agree))) Lead
            flowOut planner.flow `shouldBe` Plan
            case planner.flow of
                SomeFlow flow -> graph flow `shouldSatisfy` isRight

        it "keeps the engineer's and the 10x's flows ending in a PR, the architect's in its context, the chief's in a request's result" $
            map (flowOut . (.flow) . role) [minBound .. maxBound] `shouldBe` [PR, PR, Ctx, Result]

    describe "Effects" $
        it "each registered flow raises picks and questions, one that ships PRs its waits, a forked engineer its questions and waits, a root none: checked as this module compiles" $ do
            effectsRaised `shouldBe` (Refl, Refl, Refl, Refl, Refl)
            rootsHandled `shouldBe` (Refl, Refl, Refl, Refl)

{- | The effects each registered flow's body leaves to its handlers. The 10x
forks handled engineers: their picks are their own, their questions and
waits bubble up to the 10x.
-}
effectsRaised ::
    ( Effects EngineerS :~: '[PickE, AskE, AwaitE]
    , Effects TenXS :~: '[PickE, AskE, AwaitE]
    , Effects ChiefS :~: '[PickE, AskE, FocusE, AwaitE]
    , Effects ArchitectS :~: '[PickE, AskE]
    , Effects (ParallelS (HandleS PickE EngineerS)) :~: '[AskE, AwaitE]
    )
effectsRaised = (Refl, Refl, Refl, Refl, Refl)

-- | A registered flow, at the root, leaves nothing: its principal answers its questions, its waits settle there.
rootsHandled ::
    ( Effects (HandleS AskE (HandleS AwaitE (HandleS PickE EngineerS))) :~: '[]
    , Effects (HandleS AskE (HandleS AwaitE (HandleS PickE TenXS))) :~: '[]
    , Effects (HandleS AskE (HandleS AwaitE (HandleS PickE (HandleS FocusE ChiefS)))) :~: '[]
    , Effects (HandleS AskE (HandleS PickE ArchitectS)) :~: '[]
    )
rootsHandled = (Refl, Refl, Refl, Refl)
