{- | The ids a run's log names things by. Apart from "State.Event" so a module
the events carry, such as "State.Ask", can name a run or an event too.
-}
module State.Id (
    RunId,
    parseRunId,
    runIdText,
    numberedText,
    parseNumbered,
    EventId (..),
    eventIdText,
    parseEventId,
    Digest (..),
    digestOf,
    breaksLine,
) where

import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Read (decimal)
import Data.Word (Word64, Word8)
import Numeric (showHex)
import Numeric.Natural (Natural)

{- | Short and random, set by @init@; one log holds one run. Built only by
'parseRunId'.
-}
newtype RunId = RunId Text
    deriving stock (Eq, Ord, Show)

{- | A CLI record's id is @<run>:<seq>@ and a hook record's @h:<hash>@ (#360),
so a run id is never @h@ and holds no @:@: either would let a CLI id spell a
hook id, and append-by-id drop a distinct event. Empty is no id at all. It
holds no line break, so a hand-back line naming it stays one line (#360).
-}
parseRunId :: Text -> Maybe RunId
parseRunId raw
    | Text.null raw || raw == "h" || Text.elem ':' raw || Text.any breaksLine raw = Nothing
    | otherwise = Just (RunId raw)

runIdText :: RunId -> Text
runIdText (RunId run) = run

-- | @<run>:<n>@, the form of a CLI record's id and of a question's.
numberedText :: RunId -> Natural -> Text
numberedText (RunId run) n = run <> ":" <> Text.pack (show n)

-- | A run id holds no @:@, so the first one splits the run from the number.
parseNumbered :: Text -> Maybe (RunId, Natural)
parseNumbered raw = case Text.breakOn ":" raw of
    (run, rest) -> (,) <$> parseRunId run <*> (Text.stripPrefix ":" rest >>= number)
  where
    number digits = case decimal digits of
        Right (n, "") -> Just n
        Right _ -> Nothing
        Left _ -> Nothing

-- | What makes an append idempotent: an id already in the log is not appended again.
data EventId = Numbered RunId Natural | Hashed Digest
    deriving stock (Eq, Ord, Show)

-- | A hook record's content hash, hex.
newtype Digest = Digest Text
    deriving stock (Eq, Ord, Show)

{- | The digest of these parts: FNV-1a, 64 bits, over their UTF-8 joined by
NUL, in hex. A dedupe key, no security.
-}
digestOf :: [Text] -> Digest
digestOf = Digest . Text.pack . (`showHex` "") . BS.foldl' step 0xcbf29ce484222325 . encodeUtf8 . Text.intercalate "\0"
  where
    step :: Word64 -> Word8 -> Word64
    step hash byte = (hash `xor` fromIntegral byte) * 0x100000001b3

-- | A CLI record's id is @<run>:<seq>@, a hook record's @h:<hash>@.
eventIdText :: EventId -> Text
eventIdText = \case
    Numbered run n -> numberedText run n
    Hashed (Digest digest) -> "h:" <> digest

{- | A run id is never @h@, so a hook id never reads as a CLI one. Neither id
holds a line break, so a hand-back line naming it stays one line (#360).
-}
parseEventId :: Text -> Maybe EventId
parseEventId raw = case Text.stripPrefix "h:" raw of
    Just digest | not (Text.null digest || Text.any breaksLine digest) -> Just (Hashed (Digest digest))
    Just _ -> Nothing
    Nothing -> uncurry Numbered <$> parseNumbered raw

-- | Unicode's mandatory line breaks (UAX #14 classes BK, CR, LF and NL).
breaksLine :: Char -> Bool
breaksLine = (`elem` ['\n', '\v', '\f', '\r', '\x85', '\x2028', '\x2029'])
