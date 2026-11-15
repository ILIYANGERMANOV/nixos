module State.Category.FuelSpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (forAll, tripping)
import Hedgehog.Gen qualified as Gen
import State.Category.Fuel (Area (..), Cfg (..), Fuel (..), PerFuel (..), SkipWhen (..), atFuel, cfg, cfgLeq, fuelLabel, fuelName, monotone, parseFuel, skipsAtMost)
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

    it "reads each level's value of a PerFuel" $
        [atFuel level (PerFuel 'l' 'b' 'm') | level <- levels] `shouldBe` "lbm"

    it "calls a PerFuel monotone only when no level allows less than the one below" $
        map (monotone (<=)) [PerFuel 1 2 2, PerFuel 2 1 3, PerFuel 1 3 (2 :: Int)]
            `shouldBe` [True, False, False]

    it "orders skips: never skipping is below every rule, the agent's call above a line count" $
        [(a, b) | a <- skipWhens, b <- skipWhens, skipsAtMost a b]
            `shouldBe` [ (Never, Never)
                       , (Never, AtOrBelow 100)
                       , (Never, Skippable)
                       , (AtOrBelow 100, AtOrBelow 100)
                       , (AtOrBelow 100, Skippable)
                       , (Skippable, Skippable)
                       ]

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

    it "puts no cfg below one that has fewer areas" $
        cfgLeq base base {areas = Set.empty} `shouldBe` False
  where
    base = cfg Balanced
    levels = [minBound .. maxBound]
    skipWhens = [Never, AtOrBelow 100, Skippable]
