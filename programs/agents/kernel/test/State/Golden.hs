module State.Golden (golden) where

import Data.Text (Text)
import Data.Text qualified as Text
import Test.Hspec.Golden (Golden (..), defaultGolden)

{- | Compares with @test/golden/<file>@. A missing file fails, rather than
being written and passing, so a check never creates what it should compare;
delete the file and run the suite twice to accept a new output.
-}
golden :: FilePath -> Text -> Golden String
golden file output =
    (defaultGolden file (Text.unpack output))
        { goldenFile = "test/golden/" <> file
        , actualFile = Nothing
        , failFirstTime = True
        }
