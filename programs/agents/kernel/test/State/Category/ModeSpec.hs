module State.Category.ModeSpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (forAll, tripping)
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (LoopId (..))
import State.Category.Mode (Area (..), Cfg (..), Mode (..), Quality (..), Size (..), SkipWhen (..), cfg, cfgLeq, leq, modes, parseQuality, qualityName)
import State.Golden (golden)
import Test.Hspec (Spec, describe, it, shouldBe, shouldMatchList)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Category.Mode" $ do
    it "spells each quality as the Quality table does" $
        golden "quality-names/golden" . Text.unlines $
            map qualityName [minBound .. maxBound]

    it "parses a wire name back to its quality" . hedgehog $ do
        quality <- forAll Gen.enumBounded
        tripping quality qualityName parseQuality

    it "refuses a name in another case" $
        parseQuality "balanced" `shouldBe` Nothing

    it "refuses an unknown name" $
        parseQuality "Fast" `shouldBe` Nothing

    it "orders the six modes as #351 draws them: the 7 edges and what they imply" $
        [(m, m') | m <- modes, m' <- modes, m /= m', leq m m', not (any (between m m') modes)]
            `shouldMatchList` edges

    it "gives review 2, 3 and 5 re-reviews after the first by Quality, none when Trivial" $
        [(m, (cfg m).fuel LReview) | m <- modes]
            `shouldMatchList` [ (Mode Poc Normal, 3)
                              , (Mode Balanced Normal, 4)
                              , (Mode Max Normal, 6)
                              , (Mode Poc Trivial, 1)
                              , (Mode Balanced Trivial, 1)
                              , (Mode Max Trivial, 1)
                              ]

    it "reviews data model and auth fixes in full below Max, and interface ones too at Max" $
        [(m, (cfg m).areas) | m <- modes]
            `shouldMatchList` [ (Mode quality size, areas)
                              | (quality, areas) <-
                                    [ (Poc, Set.fromList [DataModel, Auth])
                                    , (Balanced, Set.fromList [DataModel, Auth])
                                    , (Max, Set.fromList [Interface, DataModel, Auth])
                                    ]
                              , size <- [Trivial, Normal]
                              ]

    it "cfg_is_monotone_on_the_7_edges" $
        [(m, m') | (m, m') <- edges, not (cfgLeq (cfg m) (cfg m'))] `shouldBe` []

    it "puts a cfg at or below itself" $
        cfgLeq base base `shouldBe` True

    it "puts no cfg below one that skips more or has less fuel, fan-out or areas" $
        map
            (cfgLeq base)
            [ base {skip = const Always}
            , base {fuel = const 0}
            , base {fan = const 0}
            , base {areas = Set.empty}
            ]
            `shouldBe` [False, False, False, False]
  where
    base = cfg (Mode Balanced Normal)

-- | The covering edges of #351's mode diagram, lower mode first.
edges :: [(Mode, Mode)]
edges =
    [ (Mode Poc Trivial, Mode Poc Normal)
    , (Mode Poc Trivial, Mode Balanced Trivial)
    , (Mode Poc Normal, Mode Balanced Normal)
    , (Mode Balanced Trivial, Mode Balanced Normal)
    , (Mode Balanced Trivial, Mode Max Trivial)
    , (Mode Balanced Normal, Mode Max Normal)
    , (Mode Max Trivial, Mode Max Normal)
    ]

between :: Mode -> Mode -> Mode -> Bool
between low high m = m /= low && m /= high && leq low m && leq m high
