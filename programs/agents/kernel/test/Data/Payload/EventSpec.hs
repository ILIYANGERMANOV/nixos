-- | An envelope as an @events@ row and back, and the @runs@ row of a run's first event.
module Data.Payload.EventSpec (spec) where

import Data.Entity.Event (EventRow (..))
import Data.Entity.Event qualified as Row
import Data.Entity.Run (RunRow (..))
import Data.Map.Strict qualified as Map
import Data.Payload.Event (decodeRow, eventRow, runRow)
import Data.Payload.Upcast (Upcasts (..), shipped)
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian)
import Hedgehog (forAll, tripping)
import State.Run.Ask (ChildTask (..), Link (..), Parent (..), Principal (..))
import State.Run.Codec (LineError (..))
import State.Run.Event (
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
        tripping e eventRow (decodeRow shipped)

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

    it "reads a row of another payload version as unsupported" $
        decodeRow shipped (eventRow refused) {Row.schemaVersion = 2}
            `shouldBe` Left (Unsupported 2)

    it
        "reads a row whose type it does not know, or whose payload does not fit, as malformed"
        $ map
            (decodeRow shipped)
            [ (eventRow refused) {eventType = "no_such_event"}
            , (eventRow refused) {payload = "{}"}
            ]
            `shouldSatisfy` all (\case Left (Malformed _) -> True; _ -> False)

    it "reads an aliased type as the type it names" $
        decodeRow
            (shipped {aliases = Map.singleton "refusal" "refused"})
            (eventRow refused) {eventType = "refusal"}
            `shouldBe` Right refused
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
