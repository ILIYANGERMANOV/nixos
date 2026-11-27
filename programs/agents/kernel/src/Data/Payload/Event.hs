{- | An envelope as an @events@ row and back, and the @runs@ row its first
event makes. The payload's JSON is "State.Run.Codec"'s; the columns are
"Data.Field"'s.
-}
module Data.Payload.Event (
    eventRow,
    runRow,
    Decoded (..),
    RetiredEvent (..),
    UnknownEvent (..),
    decodeRow,
    dumpLine,
) where

import Data.Aeson ((.=))
import Data.Aeson.Encoding (
    encodingToLazyByteString,
    pair,
    pairs,
    unsafeToEncoding,
 )
import Data.Entity.Event (EventRow (..))
import Data.Entity.Run (RunRow (..))
import Data.Field qualified as Field
import Data.Int (Int64)
import Data.Payload.Upcast (Upcasts (..), typeOf)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as Lazy
import State.Role (flowText)
import State.Run.Codec (
    decodePayload,
    eventType,
    payloadText,
    schemaVersion,
 )
import State.Run.Event (
    Digest,
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

{- | What a row reads as. Total: every row is one of these, so dump, reports
and SQL read any row, while an append refuses a run holding an 'Unknown'.
-}
data Decoded
    = Known Envelope
    | -- | A type that left the domain: the fold skips it.
      Retired RetiredEvent
    | {- | A row this kernel cannot read: an unknown type, another payload
      version, or a column or payload that does not fit.
      -}
      Unknown UnknownEvent
    deriving stock (Eq, Show)

data RetiredEvent = RetiredEvent
    { eventType :: Text
    , payload :: Text
    , digest :: Maybe Digest
    {- ^ The hook's record it was, if a hook wrote it: still seen, so the
    hook fired again appends nothing.
    -}
    }
    deriving stock (Eq, Show)

data UnknownEvent = UnknownEvent
    {eventType :: Text, schemaVersion :: Int64, payload :: Text}
    deriving stock (Eq, Show)

{- | The row read through these upcasts: its type renamed by the alias table
first, then retired, read, or not readable.
-}
decodeRow :: Upcasts -> EventRow -> Decoded
decodeRow upcasts row
    | Set.member kind upcasts.retired =
        maybe unknown Retired $ do
            digest <- hookDigest
            pure RetiredEvent {eventType = kind, payload = row.payload, digest}
    | row.schemaVersion /= fromIntegral schemaVersion = unknown
    | otherwise = maybe unknown Known $ do
        run <- Field.decode Field.runId row.runId
        n <- Field.natural row.seq
        ts <- Field.decode Field.time row.time
        session <- traverse (Field.decode Field.session) row.sessionId
        sha <- traverse (Field.decode Field.sha) row.headSha
        source <- maybe Cli Hook <$> hookDigest
        event <- either (const Nothing) Just (decodePayload kind row.payload)
        pure Envelope {source, seq = n, ts, run, head = sha, session, event}
  where
    kind = typeOf upcasts row.eventType
    -- Nothing when the column holds text that is no digest.
    hookDigest = traverse (Field.decode Field.digest) row.hookDigest
    unknown =
        Unknown
            UnknownEvent
                { eventType = row.eventType
                , schemaVersion = row.schemaVersion
                , payload = row.payload
                }

{- | The row as one JSON Lines line (jsonlines.org), without its newline:
every column a key in the table's order, @null@ for NULL, and @data@ spliced
verbatim from its text, a JSON object by the table's CHECK, so a duplicate
key or the key order survives. @position@, the store's own order across
runs, is left out: a run's order is its seq.
-}
dumpLine :: EventRow -> Text
dumpLine row =
    Lazy.toStrict . Lazy.decodeUtf8 . encodingToLazyByteString . pairs $
        "run_id" .= row.runId
            <> "seq" .= row.seq
            <> "schema_version" .= row.schemaVersion
            <> "type" .= row.eventType
            <> "time" .= row.time
            <> "session_id" .= row.sessionId
            <> "head_sha" .= row.headSha
            <> "hook_digest" .= row.hookDigest
            <> pair "data" (unsafeToEncoding (Text.encodeUtf8Builder row.payload))
