module State.ModeSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (forAll, tripping)
import Hedgehog.Gen qualified as Gen
import State.Mode (Cfg (..), Mode (..), Quality (..), Size (..), SkipWhen (..), cfg, cfgLeq, leq, modes, parseQuality, qualityName)
import Test.Hspec (Spec, describe, it, shouldBe, shouldMatchList)
import Test.Hspec.Golden (Golden (..), defaultGolden)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Mode" $ do
    it "spells each quality as the Quality table does" $
        golden "quality-names" . Text.unlines $
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

    it "cfg_is_monotone_on_the_7_edges" $
        [(m, m') | (m, m') <- edges, not (cfgLeq (cfg m) (cfg m'))] `shouldBe` []

    it "puts no cfg below one that skips more or has less fuel, fan-out or areas" $ do
        let base = cfg (Mode Balanced Normal)
        cfgLeq base base `shouldBe` True
        map
            (cfgLeq base)
            [ base {skip = const Always}
            , base {fuel = const 0}
            , base {fan = const 0}
            , base {areas = Set.empty}
            ]
            `shouldBe` [False, False, False, False]

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

{- | Compares with @test/golden/<name>/golden@. A missing file fails, rather
than being written and passing, so a check never creates what it should
compare; delete the file and run the suite twice to accept a new output.
-}
golden :: String -> Text -> Golden String
golden name output =
    (defaultGolden name (Text.unpack output))
        { goldenFile = "test/golden/" <> name <> "/golden"
        , actualFile = Nothing
        , failFirstTime = True
        }
