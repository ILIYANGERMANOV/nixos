module State.Cli.Render.MermaidSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Flow (Flow (..))
import State.Category.Graph (graph)
import State.Category.Ty (NotSum)
import State.Cli.Render.Mermaid (mermaid)
import State.Flow.Engineer (engineer)
import State.Flow.TenX (tenX)
import State.Flow.Triage (triaged)
import State.Golden (golden)
import State.Step.Ship (Sing (..))
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "State.Cli.Render.Mermaid" $ do
    it "draws the engineer flow" $
        golden "engineer.mmd" (render engineer)

    it "draws the 10x flow" $
        golden "10x.mmd" (render tenX)

    it "draws a flow that branches, one edge per summand" $
        golden "triage.mmd" (render triaged)

    it "tells apart two states of one step by their place in the flow" $
        render (Do SimplifyPR :> Do FixPR :> Do SimplifyPR)
            `shouldBe` Text.unlines
                [ "stateDiagram-v2"
                , "  direction LR"
                , "  state \"simplify_pr\" as simplify_pr_0"
                , "  state \"simplify_pr\" as simplify_pr_1_1"
                , "  [*] --> simplify_pr_0"
                , "  simplify_pr_0 --> fix_pr: done"
                , "  fix_pr --> simplify_pr_1_1: done"
                , "  simplify_pr_1_1 --> [*]: done"
                ]

    it "declares a scoped state by an id Mermaid takes, labelled with its name" $
        render (Scope "s" (Do SimplifyPR) :> Do FixPR)
            `shouldBe` Text.unlines
                [ "stateDiagram-v2"
                , "  direction LR"
                , "  state \"s/simplify_pr\" as s__simplify_pr"
                , "  [*] --> s__simplify_pr"
                , "  s__simplify_pr --> fix_pr: done"
                , "  fix_pr --> [*]: done"
                ]

render :: (NotSum i, NotSum o) => Flow i e o -> Text
render = either (Text.pack . show) mermaid . graph
