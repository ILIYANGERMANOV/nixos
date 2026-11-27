-- | Each column codec writes the DDL's text and reads back exactly the text it writes.
module Data.FieldSpec (spec) where

import Data.Field qualified as Field
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Hedgehog (forAll, tripping, (===))
import State.Run.Event (Digest (..), Envelope (..), SessionId (..), Sha (..))
import State.Run.EventGen (genEnvelope, genTime)
import State.Run.Id (digestOf)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "Data.Field" $ do
    describe "time" $ do
        it "writes a millisecond time in 24 characters, 3 fraction digits" $
            Field.encode Field.time (UTCTime (fromGregorian 2026 11 13) 0.1)
                `shouldBe` "2026-11-13T00:00:00.100Z"

        it "time_text_is_24_characters_and_sorts_as_time" . hedgehog $ do
            a <- forAll genTime
            b <- forAll genTime
            let text = Field.encode Field.time
            (Text.length (text a), compare (text a) (text b)) === (24, compare a b)

        it "time_round_trips" . hedgehog $ do
            t <- forAll genTime
            tripping t (Field.encode Field.time) (Field.decode Field.time)

        it
            "refuses any other spelling: no fraction, 6 digits, an offset, lowercase, a leap second"
            $ map
                (Field.decode Field.time)
                [ "2026-11-13T00:00:00Z"
                , "2026-11-13T00:00:00.000000Z"
                , "2026-11-13T00:00:00.000+00:00"
                , "2026-11-13t00:00:00.000z"
                , "2026-11-13T23:59:60.000Z"
                , "2026-02-30T00:00:00.000Z"
                ]
                `shouldSatisfy` all isNothing

    describe "sha" $ do
        it "reads a SHA-1 or SHA-256 object id, lowercase" $
            map (Field.decode Field.sha) [hex 40, hex 64]
                `shouldBe` [Just (Sha (hex 40)), Just (Sha (hex 64))]

        it "refuses a short, uppercase or 41-digit id" $
            map
                (Field.decode Field.sha)
                ["abc123", "ABCDEF0123456789ABCDEF0123456789ABCDEF01", hex 41]
                `shouldSatisfy` all isNothing

    describe "sha256" $ do
        it "round trips 64 lowercase hex" $
            (Field.encode Field.sha256 <$> Field.decode Field.sha256 (hex 64))
                `shouldBe` Just (hex 64)

        it "refuses 40 hex" $
            Field.decode Field.sha256 (hex 40) `shouldSatisfy` isNothing

    describe "session" $ do
        it "reads a session id" $
            Field.decode Field.session "s1" `shouldBe` Just (SessionId "s1")
        it "reads no empty one" $
            Field.decode Field.session "" `shouldSatisfy` isNothing

    describe "digest" $ do
        it "is FNV-1a 64 (RFC 9923), 16 hex zero padded: its test vectors" $
            map digestOf [[""], ["a"], ["foobar"]]
                `shouldBe` map Digest ["cbf29ce484222325", "af63dc4c8601ec8c", "85944171f73967e8"]

        it "refuses an unpadded or uppercase digest" $
            map (Field.decode Field.digest) ["f63dc4c8601ec8c", "AF63DC4C8601EC8C"]
                `shouldSatisfy` all isNothing

        it "digest_round_trips" . hedgehog $ do
            e <- forAll genEnvelope
            let d = digestOf [Field.encode Field.runId e.run]
            tripping d (Field.encode Field.digest) (Field.decode Field.digest)

    describe "natural" $
        it "reads a count, and no negative one" $
            map Field.natural [0, 7, -1] `shouldBe` [Just 0, Just 7, Nothing]
  where
    hex n = Text.replicate n "a"
