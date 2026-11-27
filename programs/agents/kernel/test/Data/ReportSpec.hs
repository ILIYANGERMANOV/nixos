-- | The waits report's rest time: each visit's time with no span open.
module Data.ReportSpec (spec) where

import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Report (Rest (..), SpanTime (..), Visit (..), rests, restsJson)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "Data.Report.rests" $ do
    it "counts two agents at work at once once" $
        rests [visit 0 100] [span' 10 (Just 50), span' 30 (Just 60)]
            `shouldBe` [Rest "r1" "plan" 50]

    it
        "clips a span to the visit, and holds one with no end open to the visit's end"
        $ rests [visit 100 200] [span' 50 (Just 120), span' 180 Nothing]
            `shouldBe` [Rest "r1" "plan" 60]

    it "reads only the visit's own run's spans" $
        rests [visit 0 10] [SpanTime "r2" 0 (Just 10)] `shouldBe` [Rest "r1" "plan" 10]

    it "sums a step's visits, and keeps each step apart" $
        rests
            [ visit 0 10
            , visit 20 30
            , Visit {runId = "r1", step = "review", entered = 10, left = 20}
            ]
            [span' 5 (Just 25)]
            `shouldBe` [Rest "r1" "plan" 10, Rest "r1" "review" 0]

    it "spells the rests as the JSON the waits report reads" $
        restsJson [Rest "r1" "plan" 1500] `shouldBe` "[[\"r1\",\"plan\",1500]]"

    -- Differential: the interval union against counting each millisecond.
    it "rest_is_the_milliseconds_no_span_covers" . hedgehog $ do
        (entered, left) <- forAll genInterval
        spans <- forAll (Gen.list (Range.linear 0 5) genSpan)
        let bare t = not (any (covers t) spans)
            covers t s = s.started <= t && t < fromMaybe left s.ended
        map (.millis) (rests [visit entered left] spans)
            === [fromIntegral (length (filter bare [entered .. left - 1]))]
  where
    visit entered left = Visit {runId = "r1", step = "plan", entered, left}
    span' started ended = SpanTime {runId = "r1", started, ended}

genInterval :: Gen (Int64, Int64)
genInterval = do
    a <- Gen.int64 (Range.linear 0 60)
    b <- Gen.int64 (Range.linear 0 60)
    pure (min a b, max a b + 1)

genSpan :: Gen SpanTime
genSpan = do
    (started, ended) <- genInterval
    SpanTime "r1" started <$> Gen.maybe (pure ended)
