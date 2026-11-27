-- | The one TSV printer of @state report@ and @state sql@: PostgreSQL COPY text.
module Data.TsvSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Tsv (Cell (..), Result (..), tsv)
import Hedgehog (Gen, assert, forAll, (/==), (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "Data.Tsv" $ do
    it "prints the header, then each row, each line ending in LF" $
        tsv (Result ["a", "b"] [[Text "1", Text "x"], [Text "2", Null]])
            `shouldBe` "a\tb\n1\tx\n2\t\\N\n"

    it "prints only the header for no rows" $
        tsv (Result ["a"] []) `shouldBe` "a\n"

    it "prints NULL, the empty text and the text \\N as three different cells" $
        map one [Null, Text "", Text "\\N"] `shouldBe` ["\\N", "", "\\\\N"]

    it "escapes backslash, backspace, form feed, LF, CR, tab and vertical tab" $
        one (Text "\\ \b \f \n \r \t \v")
            `shouldBe` "\\\\ \\b \\f \\n \\r \\t \\v"

    it "prints a blob as bytea hex, lowercase, its backslash escaped" $
        one (Blob (ByteString.pack [0, 15, 171, 255])) `shouldBe` "\\\\x000fabff"

    it "escapes a column name as a cell" $
        tsv (Result ["a\tb"] []) `shouldBe` "a\\tb\n"

    it "no_cell_holds_a_raw_tab_lf_or_cr" . hedgehog $ do
        header <- forAll (Gen.list (Range.linear 1 4) genText)
        rows <-
            forAll
                (Gen.list (Range.linear 0 5) (Gen.list (Range.singleton (length header)) genCell))
        let printed = tsv (Result header rows)
            lines' = Text.splitOn "\n" printed
        -- One LF per line, the last ending the text; no CR anywhere.
        length lines' === length rows + 2
        Text.count "\r" printed === 0
        assert (all (\l -> Text.count "\t" l == length header - 1) (init lines'))

    -- A blob's cell can be a text's, as in COPY: the column's type tells them apart.
    it "prints_different_texts_and_null_differently" . hedgehog $ do
        let genValue = Gen.choice [pure Null, Text <$> genText]
        a <- forAll genValue
        b <- forAll genValue
        if a == b then one a === one b else one a /== one b
  where
    one cell = case Text.lines (tsv (Result ["c"] [[cell]])) of
        [_, printed] -> printed
        other -> error ("not one row: " <> show other)

-- | A cell of any kind, its text often holding what COPY escapes.
genCell :: Gen Cell
genCell =
    Gen.choice
        [ pure Null
        , Text <$> genText
        , Blob <$> Gen.bytes (Range.linear 0 8)
        ]

genText :: Gen Text.Text
genText =
    Gen.text
        (Range.linear 0 12)
        (Gen.frequency [(3, Gen.unicode), (2, Gen.element ("\\\b\f\n\r\t\vN" :: String))])
