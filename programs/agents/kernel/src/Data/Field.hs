{- | The store's column codecs: each column type's text, as the DDL's CHECK
constraints hold it, and its strict parser, so @decode c (encode c x) == Just x@. Pure:
the store ("Effects.Store.Events") binds the text, "Data.Payload.Event" maps
an envelope through these. The domain types stay in @State/@.
-}
module Data.Field (
    Codec,
    encode,
    decode,
    time,
    sha256,
    sha,
    session,
    digest,
    runId,
    natural,
) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Numeric.Natural (Natural)
import State.Artifact (Sha256, parseSha256, sha256Text)
import State.Run.Event (
    Digest (..),
    RunId,
    SessionId (..),
    Sha (..),
    parseRunId,
    parseSessionId,
    runIdText,
 )

-- | A column's text and its parser, which takes exactly the text it writes.
data Codec a = Codec (a -> Text) (Text -> Maybe a)

encode :: Codec a -> a -> Text
encode (Codec to _) = to

decode :: Codec a -> Text -> Maybe a
decode (Codec _ from) = from

{- | A time as the store writes it: RFC 3339 s5.6, in the DDL's profile: UTC,
uppercase @T@ and @Z@, exactly 3 fraction digits, so 24 characters and text
order is time order. A finer time loses its digits past the millisecond in
the text: the Clock interpreter hands over whole milliseconds. The parser
refuses any other spelling, an offset, lowercase and the leap second @:60@.
-}
time :: Codec UTCTime
time =
    Codec (Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S.%3qZ") parse
  where
    -- %Q reads any fraction; the text it was must be the one written.
    parse raw
        | Text.length raw /= 24 || Text.take 2 (Text.drop 17 raw) == "60" = Nothing
        | otherwise =
            parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (Text.unpack raw)
                >>= \parsed ->
                    if encode time parsed == raw then Just parsed else Nothing

-- | A SHA-256 digest, as @blobs.sha256@ keys content: 64 lowercase hex.
sha256 :: Codec Sha256
sha256 = Codec sha256Text parseSha256

-- | A git object id, as @head_sha@ holds it: 40 (SHA-1) or 64 (SHA-256) lowercase hex.
sha :: Codec Sha
sha = Codec (\(Sha raw) -> raw) (fmap Sha . hex [40, 64])

-- | A harness session's id, never empty: an empty one is no session.
session :: Codec SessionId
session = Codec (\(SessionId raw) -> raw) parseSessionId

-- | A hook record's dedupe key: FNV-1a 64 as 16 lowercase hex, zero padded.
digest :: Codec Digest
digest = Codec (\(Digest raw) -> raw) (fmap Digest . hex [16])

runId :: Codec RunId
runId = Codec runIdText parseRunId

-- | A count or position from an @INTEGER@ column; a negative one is none.
natural :: Int64 -> Maybe Natural
natural n = if n < 0 then Nothing else Just (fromIntegral n)

-- | The text, when it is lowercase hex of one of these lengths.
hex :: [Int] -> Text -> Maybe Text
hex lengths raw
    | Text.length raw `elem` lengths
        && Text.all (`elem` ("0123456789abcdef" :: String)) raw =
        Just raw
    | otherwise = Nothing
