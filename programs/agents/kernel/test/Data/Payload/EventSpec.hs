-- | An envelope as an @events@ row and back, and the @runs@ row of a run's first event.
module Data.Payload.EventSpec (spec) where

import Data.Entity.Event (EventRow (..))
import Data.Entity.Event qualified as Row
import Data.Entity.Run (RunRow (..))
import Data.Payload.Event (
    Decoded (..),
    RetiredEvent (..),
    UnknownEvent (..),
    decodeRow,
    dumpLine,
    eventRow,
    runRow,
 )
import Data.Payload.Fixtures (retiring)
import Data.Payload.Upcast (shipped)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Hedgehog (Gen, forAll, tripping, (===))
import Hedgehog.Gen qualified as Gen
import State.Run.Ask (ChildTask (..), Link (..), Parent (..), Principal (..))
import State.Run.Event (
    Digest (..),
    Envelope (..),
    Event (..),
    FlowName (..),
    Note (..),
    Shape (..),
    Source (..),
    Start (..),
    TaskId (..),
 )
import State.Run.EventGen (genEnvelope, runId)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "Data.Payload.Event" $ do
    it "envelope_row_round_trips" . hedgehog $ do
        e <- forAll genEnvelope
        tripping e eventRow (known . decodeRow shipped)

    it "decode_is_total: any row decodes, its type and data kept when not known"
        . hedgehog
        $ do
            row <- forAll genAnyRow
            case decodeRow retiring row of
                Known e -> e.seq === fromIntegral row.seq
                Retired r -> (r.eventType, r.payload) === (row.eventType, row.payload)
                Unknown u ->
                    (u.eventType, u.schemaVersion, u.payload)
                        === (row.eventType, row.schemaVersion, row.payload)

    it "writes an envelope's columns, payload version 1" $
        eventRow refused
            `shouldBe` EventRow
                { runId = "00010203"
                , seq = 2
                , schemaVersion = 1
                , eventType = "refused"
                , time = "2026-11-13T00:00:00.000Z"
                , sessionId = Nothing
                , headSha = Nothing
                , hookDigest = Nothing
                , payload = "{\"message\":\"n\",\"fix\":\"f\"}"
                }

    it "makes a child's runs row from its first event alone" $
        runRow begun
            `shouldBe` Just
                RunRow
                    { id = "0a0b0c0d"
                    , parentRunId = Just "00010203"
                    , flow = "engineer"
                    , notesDir = "/child"
                    , createdAt = "2026-11-13T00:00:00.000Z"
                    }

    it "makes no runs row of an event past the first" $
        runRow refused `shouldBe` Nothing

    it "reads a row of a newer payload version as unknown" $
        decodeRow shipped (eventRow refused) {Row.schemaVersion = 2}
            `shouldBe` Unknown (unknownOf (eventRow refused) {Row.schemaVersion = 2})

    it "reads a row whose type it does not know as unknown" $
        decodeRow shipped (eventRow refused) {Row.eventType = "no_such_event"}
            `shouldBe` Unknown (unknownOf (eventRow refused) {Row.eventType = "no_such_event"})

    it "reads a row whose payload does not fit its type as unknown" $
        decodeRow shipped (eventRow refused) {Row.payload = "{}"}
            `shouldBe` Unknown (unknownOf (eventRow refused) {Row.payload = "{}"})

    it "reads an aliased type as the type it names" $
        decodeRow retiring (eventRow refused) {Row.eventType = "refusal"}
            `shouldBe` Known refused

    it "reads a row of a retired type as retired, its hook digest kept" $
        decodeRow
            retiring
            (eventRow refused)
                { Row.eventType = "legacy.note"
                , Row.payload = "{\"old\":1}"
                , Row.hookDigest = Just "0123456789abcdef"
                }
            `shouldBe` Retired
                RetiredEvent
                    { eventType = "legacy.note"
                    , payload = "{\"old\":1}"
                    , digest = Just (Digest "0123456789abcdef")
                    }

    it "reads a retired type as unknown to a kernel that never retired it" $
        decodeRow shipped (eventRow refused) {Row.eventType = "legacy.note"}
            `shouldSatisfy` \case
                Unknown _ -> True
                Known _ -> False
                Retired _ -> False

    it "dumps a row as one JSON object, null for NULL, data verbatim" $
        dumpLine (eventRow refused) {Row.payload = "{\"b\":1,\"a\":2,\"a\":3}"}
            `shouldBe` "{\"run_id\":\"00010203\",\"seq\":2,\"schema_version\":1,\"type\":\"refused\",\"time\":\"2026-11-13T00:00:00.000Z\",\"session_id\":null,\"head_sha\":null,\"hook_digest\":null,\"data\":{\"b\":1,\"a\":2,\"a\":3}}"
  where
    refused =
        Envelope
            { source = Cli
            , seq = 2
            , ts = UTCTime (fromGregorian 2026 11 13) 0
            , run = runId "00010203"
            , head = Nothing
            , session = Nothing
            , event = Refused (Note "n" "f")
            }
    begun =
        refused
            { seq = 1
            , run = runId "0a0b0c0d"
            , event =
                Started
                    Start
                        { flow = EngineerFlow
                        , notes = "/child"
                        , principal =
                            ByRole (Parent (runId "00010203") (InFan (Tasked (TaskId "t1")))) OwnPr minBound
                        , interface = Set.empty
                        }
            }

-- | The envelope a row decodes to, or why not.
known :: Decoded -> Either Decoded Envelope
known = \case
    Known e -> Right e
    other -> Left other

-- | The row as unknown to this kernel: its type, version and data as stored.
unknownOf :: EventRow -> UnknownEvent
unknownOf row =
    UnknownEvent
        { eventType = row.eventType
        , schemaVersion = row.schemaVersion
        , payload = row.payload
        }

-- | A row as any writer could leave it: a real one, any column changed.
genAnyRow :: Gen EventRow
genAnyRow = do
    row <- eventRow <$> genEnvelope
    kind <- Gen.element [row.eventType, "no_such_event", "legacy.note", "refusal"]
    version <- Gen.element [row.schemaVersion, 0, 2, maxBound]
    payload <- Gen.element [row.payload, "{}", "not json", "{\"message\":1}"]
    n <- Gen.element [row.seq, -1, 0]
    time <- Gen.element [row.time, "yesterday"]
    digest <- Gen.element [row.hookDigest, Just "XYZ", Just (Text.replicate 16 "0")]
    pure
        row
            { Row.eventType = kind
            , Row.schemaVersion = version
            , Row.payload = payload
            , Row.seq = n
            , Row.time = time
            , Row.hookDigest = digest
            }
