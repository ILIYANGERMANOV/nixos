module State.ModeSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (forAll, tripping)
import Hedgehog.Gen qualified as Gen
import State.Mode (parseQuality, qualityName)
import Test.Hspec (Spec, describe, it, shouldBe)
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
