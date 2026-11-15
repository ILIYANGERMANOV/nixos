module State.Cli.RenderSpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as Text
import State.Category.Graph (places)
import State.Cli.Render
import State.Run.RunGen (g, loadSteps)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldContain)

spec :: Spec
spec = describe "State.Cli.Render" $ do
    steps <- runIO loadSteps
    let rows = drop 2 (Text.lines (states g steps))

    describe "states" $ do
        it "has a row per state, in the flow's order" $
            (length rows, take 1 rows, take 1 (reverse rows))
                `shouldBe` (Set.size (places g), ["| gather | you | research.spawned: gather; research.handed_back: gather; enough: plan |"], ["| ready | you | done: end; skipped: end |"])

        it "names who runs each state and where each outcome goes" $
            rows
                `shouldContain` [ "| confirm | you | adjusted: gather; confirmed: draft |"
                                , "| draft | you | done: implement |"
                                ]

    it "renders the Fuel rows from the Fuel table: the meters by state, a choice's in the order it declares them, then Low's skips in the flow's order" $
        fuel g
            `shouldBe` Text.unlines
                [ "| Researchers | 1 for all, 8 calls, notes past the hand-back limit | up to 5, 15 calls, notes | one per group, 30 calls, notes, top 5 facts re-checked |"
                , "| Interview questions | up to 15 | up to 30 | up to 50 |"
                , "| Re-reviews | up to 1, blockers and Not met fixed only | up to 3 | up to 5 |"
                , "| Skippable when trivial | `simplify_plan`, `refactor` | none | none |"
                , "| Refactor | unless trivial, quick: items 1-3, no `tests.md` | above about 100 changed lines | always |"
                , "| Full review of a fix to | data model, auth | data model, auth | interface, data model, auth |"
                ]

    it "renders who answers each kind" $
        kinds
            `shouldBe` Text.unlines
                [ "| Kind | worker | engineer | 10x | user |"
                , "|---|---|---|---|---|"
                , "| Fact | forwards | answers | answers | never asked |"
                , "| Pick | forwards | answers | answers | answers |"
                , "| Design | forwards | forwards | answers if it passes the rule test | answers |"
                , "| Scope | forwards | forwards | answers if it passes the rule test | answers |"
                , "| Confirm | forwards | forwards | answers if the task plan fits the confirmed breakdown | answers |"
                , "| Security | forwards | forwards | answers if the user already answered it, or it is obvious | answers |"
                , "| Stuck | forwards | forwards | answers if no retry was spent on it yet | answers |"
                ]
