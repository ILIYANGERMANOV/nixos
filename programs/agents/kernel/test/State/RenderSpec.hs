module State.RenderSpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as Text
import State.Graph (places)
import State.Render
import State.RunGen (g, loadSteps)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldContain)

spec :: Spec
spec = describe "State.Render" $ do
    steps <- runIO loadSteps
    let rows = drop 2 (Text.lines (states g steps))

    describe "states" $ do
        it "has a row per state, in the flow's order" $
            (length rows, take 1 rows, take 1 (reverse rows))
                `shouldBe` (Set.size (places g), ["| research | researcher | done: interview; skipped: interview |"], ["| ready | you | done: end; skipped: end |"])

        it "names who runs each state and where each outcome goes" $
            rows
                `shouldContain` [ "| confirm | you | adjusted: research; confirmed: draft |"
                                , "| draft | you | done: implement |"
                                ]

    it "renders the Quality rows from the mode table" $
        quality
            `shouldBe` Text.unlines
                [ "| Proposals | simplify | simplify, alternative | simplify, alternative |"
                , "| Refactor | above about 100 changed lines, quick: items 1-3, no `tests.md` | above about 100 changed lines | always |"
                , "| Re-reviews | up to 2, blockers and Not met fixed only | up to 3 | up to 5 |"
                , "| Full review of a fix to | data model, auth | data model, auth | interface, data model, auth |"
                ]

    it "lists what Trivial skips, in the flow's order" $
        trivialSkips g
            `shouldBe` Text.unlines
                [ "- `research`: skipped"
                , "- `simplify_plan`: skipped"
                , "- `alternative`: skipped"
                , "- `refactor`: skipped"
                , "- `simplify_pr`: never skipped"
                , "- `ready`: POC skipped, Balanced never skipped, Max never skipped"
                , "- re-reviews: 0"
                , "- researchers: 1"
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
                , "| Confirm | forwards | answers if the task is `Size: Trivial` | answers if the task plan fits the confirmed breakdown | answers |"
                , "| Security | forwards | forwards | answers if the user already answered it, or it is obvious | answers |"
                , "| Stuck | forwards | forwards | answers if no retry was spent on it yet | answers |"
                ]
