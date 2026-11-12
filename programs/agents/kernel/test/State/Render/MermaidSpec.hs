module State.Render.MermaidSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import State.Cap (Step (..))
import State.Flow (Flow (..))
import State.Flows.Engineer (engineer)
import State.Flows.TenX (tenX)
import State.Golden (golden)
import State.Graph (graph)
import State.Render.Mermaid (mermaid)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "State.Render.Mermaid" $ do
    it "draws the engineer flow" $
        golden "engineer.mmd" (render engineer)

    it "draws the 10x flow" $
        golden "10x.mmd" (render tenX)

    it "tells apart two states of one step by their place in the flow" $
        render (Do Refactor :> Do Fix :> Do Refactor)
            `shouldBe` Text.unlines
                [ "stateDiagram-v2"
                , "  direction LR"
                , "  [*] --> refactor_0"
                , "  refactor_0 --> fix: done"
                , "  fix --> refactor_1_1: done"
                , "  refactor_1_1 --> [*]: done"
                ]

render :: Flow i e o -> Text
render = either (Text.pack . show) mermaid . graph
