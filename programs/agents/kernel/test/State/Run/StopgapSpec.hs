-- | A stopgap's key, after OpenTelemetry's naming, and the newest value of each in force.
module State.Run.StopgapSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Hedgehog (Gen, PropertyT, evalEither, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Run.Event (
    Event (..),
    Note (..),
    RefusalCode (..),
    Stop (..),
    StopReason (..),
 )
import State.Run.EventGen (
    genIJson,
    genStopgapAt,
    genStopgapKeyText,
    ijson,
    logOf,
    started,
    stopgapKey,
    titled,
 )
import State.Run.Fold (Refusal (..), RunState (..), replay)
import State.Run.IJson (IJson)
import State.Run.RunGen (g)
import State.Run.Stopgap
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Stopgap" $ do
    describe "a key" $ do
        it "takes every key OpenTelemetry's naming allows, as written" . hedgehog $ do
            raw <- forAll genStopgapKeyText
            fmap stopgapKeyText (parseStopgapKey raw) === Just raw

        it "refuses a valid key broken in any one way" . hedgehog $ do
            raw <- forAll genStopgapKeyText
            broken <- forAll (Gen.element breaks >>= ($ raw))
            parseStopgapKey broken === Nothing

        it "takes these keys and refuses those" $ do
            map
                (fmap stopgapKeyText . parseStopgapKey)
                ["a", "a1", "http.request.method", "db.x_y.z9"]
                `shouldBe` map Just ["a", "a1", "http.request.method", "db.x_y.z9"]
            map
                parseStopgapKey
                [ ""
                , "1a"
                , "_a"
                , ".a"
                , "a."
                , "a_"
                , "a..b"
                , "a__b"
                , "a._b"
                , "a_.b"
                , "A"
                , "aB"
                , "a-b"
                , "a b"
                , "é"
                ]
                `shouldBe` replicate 15 Nothing

    describe "the fold" $ do
        it "keeps the newest value set: a set after a set replaces it" . hedgehog $ do
            at <- forAll genStopgapAt
            older <- forAll genIJson
            newer <- forAll genIJson
            stopgaps <- live [StopgapSet at older reason, StopgapSet at newer reason]
            Map.lookup at stopgaps === Just newer

        it "drops a value unset" . hedgehog $ do
            at <- forAll genStopgapAt
            value <- forAll genIJson
            stopgaps <- live [StopgapSet at value reason, StopgapUnset at reason]
            Map.lookup at stopgaps === Nothing

        it "takes an unset of a key not set, which changes nothing" . hedgehog $ do
            pool <- forAll genPool
            events <- forAll (genStopgapEvents pool)
            at <- forAll (Gen.element pool)
            before <- live events
            after <- live (events <> [StopgapUnset at reason])
            after === Map.delete at before

        it "leaves every other key and scope as it was" . hedgehog $ do
            pool <- forAll genPool
            events <- forAll (genStopgapEvents pool)
            at <- forAll (Gen.element pool)
            change <- forAll (genChange at)
            before <- live events
            after <- live (events <> [change])
            Map.delete at after === Map.delete at before

        it "keeps the refusal the run logged last: the run moves on no stopgap" $
            (.refused) <$> replayed [Refused note, StopgapSet place (ijson "1") reason]
                `shouldBe` Right (Just note)

        it "refuses a stopgap after the run stopped" $
            replayed [Stopped halt, StopgapSet place (ijson "1") reason]
                `shouldBe` Left (AfterStop halt)
  where
    reason = titled "no typed event holds it"
    place = StopgapAt Nothing (stopgapKey "deploy.window")
    note = Note (RefusalCode "no_edge") "no edge" "state next"
    halt = Stop Blocked "why"
    breaks :: [Text.Text -> Gen Text.Text]
    breaks =
        [ pure . Text.toUpper
        , \raw -> (<> raw) <$> Gen.element ["1", "_", "."]
        , \raw -> (raw <>) <$> Gen.element ["_", "."]
        , \raw -> (\d -> raw <> d <> "x") <$> Gen.element ["..", "__", "._", "_."]
        , \raw -> (\c -> raw <> Text.singleton c) <$> Gen.element ("-/ :Aé" :: String)
        , \_ -> pure ""
        ]

-- | A run of these events after its start, at seq 0.
replayed :: [Event] -> Either Refusal RunState
replayed events = replay g (logOf (started :| events))

-- | The value of each stopgap in force after these events.
live :: (Monad m) => [Event] -> PropertyT m (Map.Map StopgapAt IJson)
live events = Map.map (.value) . (.stopgaps) <$> evalEither (replayed events)

-- | A few places, so the events drawn from them write the same key often.
genPool :: Gen [StopgapAt]
genPool = Gen.list (Range.singleton 3) genStopgapAt

genStopgapEvents :: [StopgapAt] -> Gen [Event]
genStopgapEvents pool = Gen.list (Range.linear 0 8) (Gen.element pool >>= genChange)

-- | A set or an unset of this place.
genChange :: StopgapAt -> Gen Event
genChange at =
    Gen.choice
        [ (\value -> StopgapSet at value (titled "set")) <$> genIJson
        , pure (StopgapUnset at (titled "unset"))
        ]
