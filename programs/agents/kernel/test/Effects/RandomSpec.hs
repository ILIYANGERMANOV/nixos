module Effects.RandomSpec (spec) where

import Data.ByteString qualified as BS
import Effectful (runEff)
import Effects.Random (randomBytes, runRandomIO)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "Effects.Random" $
    it "draws as many bytes as asked, fresh each time" $ do
        draws <- runEff . runRandomIO $ traverse randomBytes [32, 32]

        map BS.length draws `shouldBe` [32, 32]
        -- Equal 32-byte draws from /dev/urandom: one in 2^256.
        draws `shouldSatisfy` \case
            [first, second] -> first /= second
            _ -> False
