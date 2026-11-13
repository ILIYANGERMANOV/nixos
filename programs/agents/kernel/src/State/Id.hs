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
) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import Numeric.Natural (Natural)

{- | Short and random, set by @init@; one log holds one run. Built only by
'parseRunId'.
-}
newtype RunId = RunId Text
    deriving stock (Eq, Ord, Show)

{- | A CLI record's id is @<run>:<seq>@ and a hook record's @h:<hash>@ (#360),
so a run id is never @h@ and holds no @:@: either would let a CLI id spell a
hook id, and append-by-id drop a distinct event. Empty is no id at all.
-}
parseRunId :: Text -> Maybe RunId
parseRunId raw
    | Text.null raw || raw == "h" || Text.elem ':' raw = Nothing
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

-- | A CLI record's id is @<run>:<seq>@, a hook record's @h:<hash>@.
eventIdText :: EventId -> Text
eventIdText = \case
    Numbered run n -> numberedText run n
    Hashed (Digest digest) -> "h:" <> digest

-- | A run id is never @h@, so a hook id never reads as a CLI one.
parseEventId :: Text -> Maybe EventId
parseEventId raw = case Text.stripPrefix "h:" raw of
    Just digest | not (Text.null digest) -> Just (Hashed (Digest digest))
    Just _ -> Nothing
    Nothing -> uncurry Numbered <$> parseNumbered raw
