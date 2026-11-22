module State.Cli.ViewSpec (spec) where

import Data.Either (fromRight)
import Data.Foldable (for_)
import Data.Text qualified as Text
import State.Category.Fuel (Fuel (Balanced))
import State.Cli.Render qualified as Render
import State.Cli.View (beginText, brief, briefOf, briefSection, showRun)
import State.Protocol.Handback (tokenWords)
import State.Protocol.Hook (Begin (..), LeadSkill (..))
import State.Run.Event (AgentRole (..), Event (Gapped), StateName (..))
import State.Run.EventGen (fuelSet)
import State.Run.RunGen (g, happyPath, loadSteps, runAt)
import State.Table (agentRoles)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "the texts that need no run" $ do
    steps <- runIO loadSteps

    describe "a role's brief" $ do
        it
            "is what state brief gives at a step the role does not run, for every step runner"
            $ for_ (agentRoles steps)
            $ \role ->
                brief steps g (runAt []) role Nothing `shouldBe` Right (briefOf steps role)

        it "names every hand-back token for line 1, for every step runner" $
            for_ (agentRoles steps) $ \role ->
                briefOf steps role `shouldSatisfy` \text -> all (\word -> ("`" <> word) `Text.isInfixOf` text) tokenWords

        it "names every hand-back token for line 1 at a step the role runs" $ do
            let atImplement = runAt (fuelSet Balanced : take 13 happyPath)
            brief steps g atImplement (AgentRole "implementer") Nothing `shouldSatisfy` \case
                Right text ->
                    take 1 (Text.lines text) == ["## implement"]
                        && all (\word -> ("`" <> word) `Text.isInfixOf` text) tokenWords
                Left _ -> False

        it "gives an implementer its step's task, then the stop rule" $ do
            let text = briefOf steps (AgentRole "implementer")
            take 1 (Text.lines text) `shouldBe` ["## implement"]
            text `shouldSatisfy` (Render.stopRule `Text.isSuffixOf`)

        it "gives a review-lead the plan-wrong line" $
            briefOf steps (AgentRole "review-lead")
                `shouldSatisfy` (Render.planWrong `Text.isSuffixOf`)

        it "is nothing for a role that runs no step" $
            briefOf steps (AgentRole "Explore") `shouldBe` ""

    describe "one section of a role's brief" $ do
        let researcher = AgentRole "researcher"
            headings = filter ("## " `Text.isPrefixOf`) . Text.lines

        it "holds only the step named, then the hand-back rule" $
            case briefSection steps researcher (StateName "research") of
                Right text ->
                    (headings text, Render.handbackRule `Text.isInfixOf` text)
                        `shouldBe` (["## research"], True)
                Left _ -> expectationFailure "no research section"

        it "is the role's sections, for every section, in order" $
            mapM
                (briefSection steps researcher)
                [StateName "research", StateName "simplify_plan", StateName "standards_plan"]
                `shouldSatisfy` either
                    (const False)
                    (\texts -> concatMap headings texts == headings (briefOf steps researcher))

        it "names the role's sections when it runs no such step" $
            briefSection steps researcher (StateName "implement")
                `shouldBe` Left
                    [StateName "research", StateName "simplify_plan", StateName "standards_plan"]

    describe "state show" $ do
        it
            "lists which hook records the spawn and the hand-back of each step a subagent runs"
            $ showRun steps g (runAt []) `shouldSatisfy` \text ->
                all
                    (`Text.isInfixOf` text)
                    [ "hooks:\n"
                    , "  gather/research.spawned: the spawn hook, as the lead spawns a researcher\n"
                    , "  gather/research.handed_back: the handback hook, at its hand-back\n"
                    , "  best effort: with no recorded line after a spawn or hand-back, run state record <step>.spawned or state handback <role>\n"
                    ]

        it "lists the run's gaps, oldest first, each after its seq" $
            showRun steps g (runAt [Gapped "one", Gapped "two"])
                `shouldSatisfy` Text.isInfixOf "gaps:\n  1 one\n  2 two\n"

    describe "how work begins" $ do
        it "gives a spawned step runner its brief" $
            beginText steps Nothing (SpawnedWorker (AgentRole "fixer"))
                `shouldBe` briefOf steps (AgentRole "fixer")

        it "gives a reviewer spawned at align_plan that step's brief" $
            beginText steps (Just (g, atAlignPlan)) (SpawnedWorker (AgentRole "reviewer"))
                `shouldBe` fromRight "" (brief steps g atAlignPlan (AgentRole "reviewer") Nothing)

        it
            "gives a reviewer spawned beside the advice, at a step it does not run, no brief"
            $ beginText steps (Just (g, atReview)) (SpawnedWorker (AgentRole "reviewer"))
                `shouldBe` ""

        it
            "tells a spawned engineer its run starts at the init line of its prompt, then state next"
            $ beginText steps Nothing SpawnedLead `shouldSatisfy` \text -> all (`Text.isInfixOf` text) ["`state init` line", "`state next`"]

        it
            "tells a lead skill it begins with state init, then state next, typed or called alike"
            $ do
                beginText steps Nothing (TypedSkill EngineerSkill)
                    `shouldBe` beginText steps Nothing (CalledSkill TenXSkill)
                beginText steps Nothing (TypedSkill EngineerSkill) `shouldSatisfy` \text -> all (`Text.isInfixOf` text) ["`state init ...`", "`state next`"]
  where
    -- The plan done and refined to align_plan; the run past refactor, at review.
    atAlignPlan = runAt (fuelSet Balanced : take 9 happyPath)
    atReview = runAt (fuelSet Balanced : take 16 happyPath)
