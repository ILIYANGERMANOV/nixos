{- | The ids a run's log names things by. Apart from "State.Run.Event" so a module
the events carry, such as "State.Run.Ask", can name a run or an event too.
-}
module State.Run.Id (
    RunId,
    TaskId (..),
    TaskRef (..),
    AgentId (..),
    SpanId (..),
    TaskNo (..),
    taskNoText,
    parseTaskNo,
    parseRunId,
    runIdText,
    numberedText,
    parseNumbered,
    parseSeq,
    EventRef (..),
    eventRefText,
    parseEventRef,
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
import State.Step.Artifact (TaskId (..), breaksLine)

{- | Short and random, set by @init@; one log holds one run. Built only by
'parseRunId'.
-}
newtype RunId = RunId Text
    deriving stock (Eq, Ord, Show)

{- | A task by its identity across the run: its id within the breakdown
logged at this seq, the @breakdown.done@ or the @task_added@ that started it.
A new breakdown may reuse an id.
-}
data TaskRef = TaskRef {task :: TaskId, breakdown :: Natural}
    deriving stock (Eq, Ord, Show)

-- | A subagent's id, as its agent gives it: Claude Code's are hex.
newtype AgentId = AgentId {agentIdText :: Text}
    deriving stock (Eq, Show)

-- | A span, a subagent of the run's lead: the seq of its @span_started@ line.
newtype SpanId = SpanId {spanSeq :: Natural}
    deriving stock (Eq, Ord, Show)

{- | A chief's request, by the order the run opened it: @r1@, @r2@, ...
Not a 'TaskId', which names a task of a fan-out's breakdown.
-}
newtype TaskNo = TaskNo Natural
    deriving stock (Eq, Ord, Show)

taskNoText :: TaskNo -> Text
taskNoText (TaskNo n) = "r" <> Text.pack (show n)

-- | @r<n>@, @n@ from 1.
parseTaskNo :: Text -> Maybe TaskNo
parseTaskNo raw = case decimal <$> Text.stripPrefix "r" raw of
    Just (Right (n, "")) | n > 0 -> Just (TaskNo n)
    _ -> Nothing

{- | A CLI record's id is @<run>:<seq>@ and a hook record's @h:<hash>@ (#360),
so a run id is never @h@ and holds no @:@: either would let a CLI id spell a
hook id, and append-by-id drop a distinct event. Empty is no id at all. It
holds no line break, so a hand-back line naming it stays one line (#360).
-}
parseRunId :: Text -> Maybe RunId
parseRunId raw
    | Text.null raw || raw == "h" || Text.elem ':' raw || Text.any breaksLine raw =
        Nothing
    | otherwise = Just (RunId raw)

runIdText :: RunId -> Text
runIdText (RunId run) = run

-- | @<run>:<n>@, the form of a CLI record's id and of a question's.
numberedText :: RunId -> Natural -> Text
numberedText (RunId run) n = run <> ":" <> Text.pack (show n)

-- | A run id holds no @:@, so the first one splits the run from the number.
parseNumbered :: Text -> Maybe (RunId, Natural)
parseNumbered raw = case Text.breakOn ":" raw of
    (run, rest) -> (,) <$> parseRunId run <*> (Text.stripPrefix ":" rest >>= parseSeq)

-- | A line's seq in its run's log: digits alone.
parseSeq :: Text -> Maybe Natural
parseSeq digits = case decimal digits of
    Right (n, "") -> Just n
    Right _ -> Nothing
    Left _ -> Nothing

{- | A line of any run, by its run and its seq: @<run>:<seq>@, the form
a CLI record's id takes, as a gap and its evidence name a line.
-}
data EventRef = EventRef {run :: RunId, seq :: Natural}
    deriving stock (Eq, Show)

eventRefText :: EventRef -> Text
eventRefText ref = numberedText ref.run ref.seq

parseEventRef :: Text -> Maybe EventRef
parseEventRef = fmap (uncurry EventRef) . parseNumbered

-- | What makes an append idempotent: an id already in the log is not appended again.
data EventId = Numbered RunId Natural | Hashed Digest
    deriving stock (Eq, Ord, Show)

-- | A hook record's content hash, hex.
newtype Digest = Digest Text
    deriving stock (Eq, Ord, Show)

{- | The digest of these parts: FNV-1a 64 (RFC 9923), over their UTF-8 joined
by NUL, as 16 lowercase hex digits, zero padded. A dedupe key, no security.
-}
digestOf :: [Text] -> Digest
digestOf =
    Digest
        . Text.justifyRight 16 '0'
        . Text.pack
        . (`showHex` "")
        . BS.foldl' step 0xcbf29ce484222325
        . encodeUtf8
        . Text.intercalate "\0"
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
    Just digest
        | not (Text.null digest || Text.any breaksLine digest) ->
            Just (Hashed (Digest digest))
    Just _ -> Nothing
    Nothing -> uncurry Numbered <$> parseNumbered raw
