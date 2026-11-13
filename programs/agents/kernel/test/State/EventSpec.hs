module State.EventSpec (spec) where

import State.Event (parseRunId, runIdText)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "State.Event" $ do
    it "refuses run id h, whose CLI ids would spell hook ids" $
        parseRunId "h" `shouldBe` Nothing

    it "refuses a run id holding a colon, as h:1 would spell a hook id" $
        parseRunId "h:1" `shouldBe` Nothing

    it "refuses an empty run id" $
        parseRunId "" `shouldBe` Nothing

    it "takes a short random run id as written" $
        runIdText <$> parseRunId "r7f2" `shouldBe` Just "r7f2"
