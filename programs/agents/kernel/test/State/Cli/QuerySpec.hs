-- | A report's @--since@: any RFC 3339 date-time, as the store's UTC text.
module State.Cli.QuerySpec (spec) where

import Data.Field qualified as Field
import State.Cli.Query (parseSince)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "parseSince" $ do
    it "takes Z, an offset and any fraction, as UTC" $
        map
            (fmap (Field.encode Field.time) . parseSince)
            [ "2026-11-27T09:00:00Z"
            , "2026-11-27T11:00:00.5+02:00"
            , "2026-11-27T09:00:00.123456Z"
            ]
            `shouldBe` map
                Just
                [ "2026-11-27T09:00:00.000Z"
                , "2026-11-27T09:00:00.500Z"
                , "2026-11-27T09:00:00.124Z"
                ]

    it
        "rounds a fraction past the millisecond up, so an earlier stored time stays before it"
        $ fmap (Field.encode Field.time) (parseSince "2026-11-27T23:59:59.9995Z")
            `shouldBe` Just "2026-11-28T00:00:00.000Z"

    it "refuses what is no date-time" $
        map parseSince ["yesterday", "2026-11-27", "2026-11-27T09:00:00"]
            `shouldBe` [Nothing, Nothing, Nothing]
