{- | An envelope as an @events@ row and back, and the @runs@ row its first
event makes. The payload's JSON is "State.Run.Codec"'s; the columns are
"Data.Field"'s.
-}
module Data.Payload.Event (eventRow, runRow, decodeRow) where

import Data.Entity.Event (EventRow (..))
import Data.Entity.Run (RunRow (..))
import Data.Field qualified as Field
import Data.Payload.Upcast (Upcasts, typeOf)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Role (flowText)
import State.Run.Codec (
    LineError (..),
    decodePayload,
    eventType,
    payloadText,
    schemaVersion,
 )
import State.Run.Event (
    Envelope (..),
    Event (..),
    Parent (..),
    Principal (..),
    Source (..),
    Start (..),
 )

eventRow :: Envelope -> EventRow
eventRow e =
    EventRow
        { runId = Field.encode Field.runId e.run
        , seq = fromIntegral e.seq
        , schemaVersion = fromIntegral schemaVersion
        , eventType = eventType e.event
        , time = Field.encode Field.time e.ts
        , sessionId = Field.encode Field.session <$> e.session
        , headSha = Field.encode Field.sha <$> e.head
        , hookDigest = case e.source of
            Cli -> Nothing
            Hook digest -> Just (Field.encode Field.digest digest)
        , payload = payloadText e.event
        }

{- | The run's @runs@ row, when this is its first event, @started@: a pure
function of it, so the index cannot say what the log does not.
-}
runRow :: Envelope -> Maybe RunRow
runRow e = case e of
    Envelope {seq = 1, event = Started start} ->
        Just
            RunRow
                { id = Field.encode Field.runId e.run
                , parentRunId = Field.encode Field.runId <$> parentOf start.principal
                , flow = flowText start.flow
                , notesDir = Text.pack start.notes
                , createdAt = Field.encode Field.time e.ts
                }
    Envelope {} -> Nothing
  where
    parentOf = \case
        ByRole parent _ _ -> Just parent.run
        ByUser _ -> Nothing
        ByCaller _ -> Nothing

{- | The envelope a row holds, or why it is not read: another payload
version than this kernel's, or a column or payload that does not parse.
-}
decodeRow :: Upcasts -> EventRow -> Either LineError Envelope
decodeRow upcasts row
    | row.schemaVersion /= fromIntegral schemaVersion =
        Left (Unsupported (fromIntegral row.schemaVersion))
    | otherwise = either (Left . Malformed) Right $ do
        run <- column "run_id" Field.runId row.runId
        n <- maybe (Left "seq is negative") Right (Field.natural row.seq)
        ts <- column "time" Field.time row.time
        session <- traverse (column "session_id" Field.session) row.sessionId
        sha <- traverse (column "head_sha" Field.sha) row.headSha
        source <-
            maybe Cli Hook <$> traverse (column "hook_digest" Field.digest) row.hookDigest
        event <- decodePayload (typeOf upcasts row.eventType) row.payload
        pure Envelope {source, seq = n, ts, run, head = sha, session, event}
  where
    column :: Text -> Field.Codec a -> Text -> Either Text a
    column name codec raw =
        maybe
            (Left (name <> " " <> Text.pack (show raw) <> " does not parse"))
            Right
            (Field.decode codec raw)
