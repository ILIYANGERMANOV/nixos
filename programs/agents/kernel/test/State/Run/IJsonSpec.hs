-- | A stopgap's value: I-JSON (RFC 7493), one rule at a time.
module State.Run.IJsonSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Char (chr)
import Data.Either (isRight)
import Data.Text qualified as Text
import Hedgehog (cover, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric (showHex)
import State.Run.EventGen (genIJson, genText)
import State.Run.IJson
import State.Show (jsonText)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.IJson" $ do
    it "reads any JSON value, a nested null too" $
        map
            (fmap ijsonValue . parseIJson)
            ["\"x\"", " {\"a\": [1, null]} ", "-9007199254740991", "1.5", "true"]
            `shouldSatisfy` all isRight

    it "reads back the value it writes" . hedgehog $ do
        value <- forAll genIJson
        parseIJson (jsonText (ijsonValue value)) === Right value

    describe "refuses" $ do
        it "text that is no JSON: bad syntax, or text after the value" $
            map parseIJson ["{", "1 2", "", "'x'"] `shouldSatisfy` all notJson

        it "a lone surrogate, escaped, in a string or a key" . hedgehog $ do
            unit <-
                forAll
                    ( Gen.choice
                        [Gen.int (Range.linear 0xD800 0xDBFF), Gen.int (Range.linear 0xDC00 0xDFFF)]
                    )
            asKey <- forAll Gen.bool
            cover 20 "a high surrogate" (unit < 0xDC00)
            cover 20 "a low surrogate" (unit >= 0xDC00)
            let escaped = "\"a\\u" <> Text.pack (showHex unit "") <> "b\""
            notJson (parseIJson (if asKey then "{" <> escaped <> ": 1}" else escaped))
                === True

        it "an object repeating a key, at any depth" . hedgehog $ do
            key <- forAll genText
            -- Each level up an array or an object: True is an array.
            levels <- forAll (Gen.list (Range.linear 0 4) Gen.bool)
            first <- forAll genIJson
            second <- forAll genIJson
            let repeated =
                    "{"
                        <> jsonText (String key)
                        <> ": "
                        <> jsonText (ijsonValue first)
                        <> ", "
                        <> jsonText (String key)
                        <> ": "
                        <> jsonText (ijsonValue second)
                        <> "}"
            parseIJson (foldr nest repeated levels)
                === Left (RepeatedKey (Key.fromText key))

        it "an integer past 2^53-1 either way, keeping those within" . hedgehog $ do
            sign <- forAll (Gen.element [1, -1])
            n <-
                forAll
                    ( Gen.choice
                        [ Gen.integral (Range.linearFrom 0 (negate maxIJsonInteger) maxIJsonInteger)
                        , Gen.element [maxIJsonInteger, negate maxIJsonInteger]
                        , (* sign)
                            <$> Gen.integral (Range.exponential (maxIJsonInteger + 1) (10 ^ (40 :: Int)))
                        ]
                    )
            cover 20 "within" (abs n <= maxIJsonInteger)
            cover 10 "past, positive" (n > maxIJsonInteger)
            cover 10 "past, negative" (n < negate maxIJsonInteger)
            fmap ijsonValue (parseIJson (Text.pack (show n)))
                === if abs n <= maxIJsonInteger
                    then Right (Number (fromInteger n))
                    else Left (BigInteger (fromInteger n))

        it "an integer written with an exponent, past 2^53-1, at once however large" $ do
            map parseIJson ["1e16", "-1E300"]
                `shouldBe` [Left (BigInteger 1e16), Left (BigInteger (-1e300))]
            -- Never expanded: a literal of it here would be.
            parseIJson "1e1000000000" `shouldSatisfy` \case
                Left (BigInteger _) -> True
                _ -> False

        it "a fraction past a double's range" $
            parseIJson "1.5e-400" `shouldBe` Left (OutOfRange 1.5e-400)

        it
            "each of the 66 noncharacters, in a string or a key, and none of their neighbours"
            $ do
                map (parseIJson . quoted) noncharacters
                    `shouldBe` map (Left . Noncharacter) noncharacters
                map (\c -> parseIJson ("{" <> quoted c <> ": 1}")) noncharacters
                    `shouldBe` map (Left . Noncharacter) noncharacters
                map
                    (parseIJson . quoted . chr)
                    [0xFDCF, 0xFDF0, 0xFFFD, 0x10000, 0x1FFFD, 0x10FFFD]
                    `shouldSatisfy` all isRight

        it "a noncharacter anywhere in a string" . hedgehog $ do
            c <- forAll (Gen.element noncharacters)
            before <- forAll genPlain
            after <- forAll genPlain
            parseIJson (jsonText (String (before <> Text.singleton c <> after)))
                === Left (Noncharacter c)

        it "a null at the top, whatever spacing it has" $
            map parseIJson ["null", "  null\n"]
                `shouldBe` [Left TopLevelNull, Left TopLevelNull]

        it "a value whose encoding passes 1024 octets, however it was spaced" . hedgehog $ do
            size <-
                forAll
                    ( Gen.frequency
                        [(1, pure 1022), (1, pure 1023), (8, Gen.int (Range.linear 0 1100))]
                    )
            spaces <- forAll (Gen.int (Range.linear 0 3))
            -- The quotes add two octets: a string of 1022 is the largest kept.
            let raw = Text.replicate spaces " " <> jsonText (String (Text.replicate size "a"))
            cover 5 "at the cap" (size == 1022)
            cover 5 "one past" (size == 1023)
            fmap ijsonValue (parseIJson raw)
                === if size + 2 <= 1024
                    then Right (String (Text.replicate size "a"))
                    else Left (OverCap (fromIntegral size + 2))
  where
    notJson = \case
        Left (NotJson _) -> True
        _ -> False
    nest asArray inner = if asArray then "[" <> inner <> "]" else "{\"w\": " <> inner <> "}"
    quoted c = "\"" <> Text.singleton c <> "\""
    genPlain = Gen.text (Range.linear 0 5) Gen.alphaNum

-- | Unicode's 66 noncharacters: U+FDD0..U+FDEF, and the last two code points of each of the 17 planes.
noncharacters :: [Char]
noncharacters =
    map
        chr
        ( [0xFDD0 .. 0xFDEF]
            <> concat
                [[plane * 0x10000 + 0xFFFE, plane * 0x10000 + 0xFFFF] | plane <- [0 .. 16]]
        )
