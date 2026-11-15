module State.Category.FuelSpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (forAll, tripping)
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (LoopId (..), OptId (..))
import State.Category.Fuel (Area (..), Cfg (..), Fuel (..), SkipWhen (..), cfg, cfgLeq, fuelLabel, fuelName, parseFuel)
import State.Golden (golden)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Category.Fuel" $ do
    it "spells each level on the wire and as the Fuel table does" $
        golden "fuel-names/golden" . Text.unlines $
            [fuelName level <> " " <> fuelLabel level | level <- levels]

    it "parses a wire name back to its level" . hedgehog $ do
        level <- forAll Gen.enumBounded
        tripping level fuelName parseFuel

    it "refuses a name in another case" $
        parseFuel "Balanced" `shouldBe` Nothing

    it "refuses an unknown name" $
        parseFuel "fast" `shouldBe` Nothing

    it "gives review 1, 3 and 5 re-reviews after the first by level" $
        [(level, (cfg level).rounds LReview) | level <- levels]
            `shouldBe` [(Low, 2), (Balanced, 4), (Max, 6)]

    it "leaves research, the plan's simplify and the refactor skippable at Low only" $
        [(level, [optId | optId <- [minBound .. maxBound], (cfg level).skip optId == Skippable]) | level <- levels]
            `shouldBe` [(Low, [ORes, OSimp, ORefactor]), (Balanced, []), (Max, [])]

    it "reviews data model and auth fixes in full below Max, and interface ones too at Max" $
        [(level, (cfg level).areas) | level <- levels]
            `shouldBe` [ (Low, Set.fromList [DataModel, Auth])
                       , (Balanced, Set.fromList [DataModel, Auth])
                       , (Max, Set.fromList [Interface, DataModel, Auth])
                       ]

    it "cfg_is_monotone: each level does at least the work of the one below" $
        [(low, high) | (low, high) <- zip levels (drop 1 levels), not (cfgLeq (cfg low) (cfg high))] `shouldBe` []

    it "puts a cfg at or below itself" $
        cfgLeq base base `shouldBe` True

    it "puts no cfg below one that skips more or has fewer rounds, fan-out or areas" $
        map
            (cfgLeq base)
            [ base {skip = const Skippable}
            , base {rounds = const 0}
            , base {fan = const 0}
            , base {areas = Set.empty}
            ]
            `shouldBe` [False, False, False, False]
  where
    base = cfg Balanced
    levels = [minBound .. maxBound]
