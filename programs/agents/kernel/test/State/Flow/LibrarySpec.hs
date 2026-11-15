module State.Flow.LibrarySpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import State.Category.Fuel (Fuel (..), PerFuel (..), SkipWhen (..), atFuel)
import State.Category.Graph (Arrow (..), Edge (..), Empty (..), LoopAt (..), OpenGraph (..), graph)
import State.Flow.Engineer (engineer)
import State.Flow.Library (agree, build, describe, fixLoop, fixReReview, gather, propose, review, reviewed, ship)
import Test.Hspec (Spec, it, shouldBe)
import Test.Hspec qualified as Hspec

spec :: Spec
spec = Hspec.describe "State.Flow.Library" $ do
    it "builds every flow" $
        [ name
        | (name, Left _) <-
            [ ("agree", graph agree)
            , ("gather", graph gather)
            , ("propose", graph propose)
            , ("build", graph build)
            , ("review", graph review)
            , ("fixReReview", graph fixReReview)
            , ("reviewed", graph reviewed)
            , ("describe", graph describe)
            , ("ship", graph ship)
            ]
        ]
            `shouldBe` ([] :: [String])

    it "stops the run in every loop out of fuel" $
        [Map.toList . fmap (.onEmpty) . (.loops) <$> built | built <- [graph agree, graph reviewed, graph ship]]
            `shouldBe` [ Right [("gather", Stops), ("plan", Stops)]
                       , Right [("fix", Stops)]
                       , Right [("ci", Stops)]
                       ]

    it "gives the fix loop 1, 3 and 5 re-reviews, plus a last round's final pick, by level" $
        ((.rounds) <$>) . Map.lookup fixLoop . (.loops) <$> graph reviewed
            `shouldBe` Right (Just (PerFuel 2 4 6))

    it "leaves research, the plan's simplify and the refactor skippable at Low only" $
        [(level, skippable level <$> graph engineer) | level <- [minBound .. maxBound]]
            `shouldBe` [(Low, Right (Set.fromList ["refactor", "research", "simplify_plan"])), (Balanced, Right Set.empty), (Max, Right Set.empty)]
  where
    skippable level g = Set.fromList [name | Edge {arrow = Skip name when} <- Map.elems g.edges, atFuel level when == Skippable]
