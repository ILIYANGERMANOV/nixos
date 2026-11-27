{- | A stopgap: a fact an agent records when no typed command fits, by key,
for the run or one of its tasks. The kernel never reads one to decide: it
keeps the newest value of each key, for a fresh agent and the store's
@stopgaps@ table to read.
-}
module State.Run.Stopgap (
    StopgapKey,
    parseStopgapKey,
    stopgapKeyText,
    stopgapKeyRule,
    StopgapAt (..),
) where

import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Run.Id (TaskRef)

{- | A key after OpenTelemetry's attribute naming: lowercase Latin letters,
digits, @_@ and @.@ as the namespace delimiter; it starts with a letter,
ends with a letter or digit, and no two delimiters touch. Built only by
'parseStopgapKey'.
-}
newtype StopgapKey = StopgapKey Text
    deriving stock (Eq, Ord, Show)

parseStopgapKey :: Text -> Maybe StopgapKey
parseStopgapKey raw = case (Text.uncons raw, Text.unsnoc raw) of
    (Just (first, _), Just (_, final))
        | isAsciiLower first
        , isAsciiLower final || isDigit final
        , Text.all allowed raw
        , not (any (`Text.isInfixOf` raw) ["..", "__", "._", "_."]) ->
            Just (StopgapKey raw)
    _ -> Nothing
  where
    allowed c = isAsciiLower c || isDigit c || delimiter c
    delimiter c = c == '_' || c == '.'

stopgapKeyText :: StopgapKey -> Text
stopgapKeyText (StopgapKey key) = key

-- | The key grammar, in words, for a refusal to show.
stopgapKeyRule :: Text
stopgapKeyRule =
    "a key as OpenTelemetry names attributes: lowercase letters, digits, _ and ., starting with a letter, ending with a letter or digit, no two of _ and . in a row"

{- | Where a stopgap lives: the run's when it names no task, else the task's.
Its newest value is the one in force ("State.Run.Fold").
-}
data StopgapAt = StopgapAt {scope :: Maybe TaskRef, key :: StopgapKey}
    deriving stock (Eq, Ord, Show)
