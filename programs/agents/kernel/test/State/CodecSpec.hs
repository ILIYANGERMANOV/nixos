module State.CodecSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Hedgehog (forAll, tripping)
import State.Codec (LineError (..), LogError (..), decodeLine, decodeLog, encodeLine)
import State.Event (Envelope (..), Event (..), Outcome (..), RunId (..), Sha (..), Source (..))
import State.EventGen (genEnvelope)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Codec" $ do
    it "codec_round_trips" . hedgehog $ do
        envelope <- forAll genEnvelope
        tripping envelope encodeLine decodeLine

    it "writes the line #360 documents, keys in its order" $
        encodeLine reviewRows
            `shouldBe` "{\"v\":3,\"id\":\"r7f2:12\",\"seq\":12,\"ts\":\"2026-11-12T10:00:00Z\",\"run\":\"r7f2\",\"head\":\"abc123\",\"session\":null,\"type\":\"review.rows\",\"data\":{\"head\":\"abc123\"}}"

    it "refuses a version 1 log, the Python state's with no version" $
        decodeLine pythonV1 `shouldBe` Left (Unsupported 1)

    it "refuses a version 2 log, the Python state's" $
        decodeLine pythonV2 `shouldBe` Left (Unsupported 2)

    it "refuses an unknown version" $
        decodeLine (encodeLine reviewRows `replacing` ("\"v\":3", "\"v\":4")) `shouldBe` Left (Unsupported 4)

    it "names the first line of a log it does not read" $
        decodeLog (encodeLine reviewRows <> "\n" <> pythonV2 <> "\n") `shouldBe` Left (LogError 2 (Unsupported 2))

    it "reads a log line by line, its last newline ending the last line" $
        decodeLog (encodeLine reviewRows <> "\n" <> encodeLine reviewRows <> "\n") `shouldBe` Right [reviewRows, reviewRows]

    it "refuses a CLI id that names another seq" $
        decodeLine (encodeLine reviewRows `replacing` ("r7f2:12", "r7f2:11")) `shouldSatisfy` malformed

    it "refuses an unknown event type" $
        decodeLine (encodeLine reviewRows `replacing` ("review.rows", "review.maybe")) `shouldSatisfy` malformed

    it "refuses a red CI result with no failing check" $
        decodeLine (encodeLine reviewRows `replacing` ("review.rows", "await_ci.red") `replacing` ("{\"head\":\"abc123\"}", "{\"head\":\"abc123\",\"failing\":[]}"))
            `shouldSatisfy` malformed

-- | #360's example line.
reviewRows :: Envelope
reviewRows =
    Envelope
        { source = Cli
        , seq = 12
        , ts = UTCTime (fromGregorian 2026 11 12) 36000
        , run = RunId "r7f2"
        , head = Just (Sha "abc123")
        , session = Nothing
        , event = Took (ReviewRows (Sha "abc123"))
        }

-- | Lines the Python @state@ wrote, @programs/agents/state/codec.py@.
pythonV1, pythonV2 :: Text
pythonV1 = "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"delegated\":false}}"
pythonV2 = "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"delegated\":false,\"version\":2}}"

replacing :: Text -> (Text, Text) -> Text
replacing whole (old, new) = Text.replace old new whole

malformed :: Either LineError a -> Bool
malformed = \case
    Left (Malformed _) -> True
    Left (Unsupported _) -> False
    Right _ -> False
