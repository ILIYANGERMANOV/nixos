module State.Flows.BlocksSpec (spec) where

import Data.Map.Strict qualified as Map
import State.Flow (LoopId (..))
import State.Flows.Blocks (agree, build, describe, gather, propose, review, ship)
import State.Graph (Empty (..), LoopAt (..), OpenGraph (..), graph)
import Test.Hspec (Spec, it, shouldBe)
import Test.Hspec qualified as Hspec

spec :: Spec
spec = Hspec.describe "State.Flows.Blocks" $ do
    it "builds every block" $
        [ name
        | (name, Left _) <-
            [ ("agree", graph agree)
            , ("gather", graph gather)
            , ("propose", graph propose)
            , ("build", graph build)
            , ("review", graph review)
            , ("describe", graph describe)
            , ("ship", graph ship)
            ]
        ]
            `shouldBe` ([] :: [String])

    it "takes review's exit when out of fuel, and stops the run in every other loop" $
        [Map.toList . fmap (.onEmpty) . (.loops) <$> built | built <- [graph agree, graph review, graph ship]]
            `shouldBe` [ Right [(LGather, Stops), (LPlan, Stops)]
                       , Right [(LReview, Exits)]
                       , Right [(LCi, Stops)]
                       ]
