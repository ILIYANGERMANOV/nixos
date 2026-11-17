module State.Cli.ViewSpec (spec) where

import Data.Foldable (for_)
import Data.Text qualified as Text
import State.Cli.Render qualified as Render
import State.Cli.View (beginText, brief, briefOf)
import State.Protocol.Handback (tokenWords)
import State.Protocol.Hook (Begin (..), LeadSkill (..))
import State.Run.Event (AgentRole (..), Event (Took))
import State.Run.RunGen (happyPath, loadSteps, runAt)
import State.Table (agentRoles)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "the texts that need no run" $ do
    steps <- runIO loadSteps

    describe "a role's brief" $ do
        it "is what state brief gives at a step the role does not run, for every step runner" $
            for_ (agentRoles steps) $ \role ->
                brief steps (runAt []) role Nothing `shouldBe` Right (briefOf steps role)

        it "names every hand-back token for line 1, for every step runner" $
            for_ (agentRoles steps) $ \role ->
                briefOf steps role `shouldSatisfy` \text -> all (\word -> ("`" <> word) `Text.isInfixOf` text) tokenWords

        it "names every hand-back token for line 1 at a step the role runs" $ do
            let atImplement = runAt (map (Took mempty) (take 7 happyPath))
            brief steps atImplement (AgentRole "implementer") Nothing `shouldSatisfy` \case
                Right text -> take 1 (Text.lines text) == ["## implement"] && all (\word -> ("`" <> word) `Text.isInfixOf` text) tokenWords
                Left _ -> False

        it "gives an implementer its step's task, then the stop rule" $ do
            let text = briefOf steps (AgentRole "implementer")
            take 1 (Text.lines text) `shouldBe` ["## implement"]
            text `shouldSatisfy` (Render.stopRule `Text.isSuffixOf`)

        it "gives a review-lead the plan-wrong line" $
            briefOf steps (AgentRole "review-lead") `shouldSatisfy` (Render.planWrong `Text.isSuffixOf`)

        it "is nothing for a role that runs no step" $
            briefOf steps (AgentRole "Explore") `shouldBe` ""

    describe "how work begins" $ do
        it "gives a spawned step runner its brief" $
            beginText steps (SpawnedWorker (AgentRole "fixer")) `shouldBe` briefOf steps (AgentRole "fixer")

        it "tells a spawned engineer its run starts at the init line of its prompt, then state next" $
            beginText steps SpawnedLead `shouldSatisfy` \text -> all (`Text.isInfixOf` text) ["`state init` line", "`state next`"]

        it "tells a lead skill it begins with state init, then state next, typed or called alike" $ do
            beginText steps (TypedSkill EngineerSkill) `shouldBe` beginText steps (CalledSkill TenXSkill)
            beginText steps (TypedSkill EngineerSkill) `shouldSatisfy` \text -> all (`Text.isInfixOf` text) ["`state init ...`", "`state next`"]
