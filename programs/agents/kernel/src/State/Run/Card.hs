{- | A chief's requests as cards, read off its log: where each stands, what
was decided in it, what it still asks, and how to take a waiting one up
again. Derived, never stored: the log line by line ('State.Run.Fold.trace')
says which request each line was logged in.
-}
module State.Run.Card (
    Card (..),
    Standing (..),
    ResumeAdvice (..),
    cards,
    advice,
    resumeAdvice,
    cacheLife,
    safetyBuffer,
    resumeWindow,
) where

import Control.Applicative ((<|>))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import State.Run.Ask (OneLine, QId, Question (..), Reply)
import State.Run.Event (AgentId, Asking (..), Envelope (..), StateName, TaskNo)
import State.Run.Fold (Pending (..), RunState (..), Suspension (..), Worker (..), given, nodeName, waitsAt)

-- | A request: its number, whether it waits, its state, its decisions and open questions, and its last worker.
data Card = Card
    { task :: TaskNo
    , standing :: Standing
    , node :: StateName
    , decisions :: [(QId, Reply)]
    , open :: [Question]
    , agent :: Maybe AgentId
    }
    deriving stock (Eq, Show)

-- | In focus, or waiting since the line that suspended it, where it stood in the lead's words.
data Standing = InFocus | Paused UTCTime OneLine
    deriving stock (Eq, Show)

-- | How to take a waiting request's work up again: its worker, while its cache lives, else afresh.
data ResumeAdvice = ResumeAgent AgentId | FreshFromCard
    deriving stock (Eq, Show)

{- | The card of each request open in the run: the one in focus, then each
waiting one, by number.
-}
cards :: NonEmpty (Envelope, RunState) -> [Card]
cards logged =
    cardOf InFocus final.focus (nodeName final.at)
        : [cardOf (Paused at suspension.summary) task (nodeName (waitsAt suspension)) | (task, suspension) <- Map.toList final.suspended, Just at <- [(spanOf task).pausedAt]]
  where
    final = snd (NonEmpty.last logged)
    spans = spansOf logged
    spanOf task = Map.findWithDefault emptySpan task spans
    cardOf standing task node =
        let here = spanOf task
         in Card
                { task
                , standing
                , node
                , decisions = [(qid, reply) | (qid, reply) <- given final, qid `elem` here.asked]
                , open = [p.asking.question | p <- final.pending, p.asking.question.qid `elem` here.asked]
                , agent = here.lastWorker
                }

{- | The advice for a card at this time: none for the request in focus or
one whose span spawned no worker.
-}
advice :: UTCTime -> Card -> Maybe ResumeAdvice
advice now card = case card.standing of
    InFocus -> Nothing
    Paused at _ -> resumeAdvice at now <$> card.agent

{- | A worker paused under 'resumeWindow' is resumed, its prompt cache still
warm; one paused longer starts afresh from the card, as resuming it would
reread its whole context uncached.
-}
resumeAdvice :: UTCTime -> UTCTime -> AgentId -> ResumeAdvice
resumeAdvice pausedAt now agent
    | diffUTCTime now pausedAt < resumeWindow = ResumeAgent agent
    | otherwise = FreshFromCard

-- | How long a paused worker is still resumed: the cache's life less the 'safetyBuffer'.
resumeWindow :: NominalDiffTime
resumeWindow = cacheLife - safetyBuffer

-- | The prompt cache's lifetime: 5 minutes (https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching).
cacheLife :: NominalDiffTime
cacheLife = 300

{- | The user's margin under 'cacheLife': the resume message itself takes
time to reach the worker, so a pause near the edge counts as cold.
-}
safetyBuffer :: NominalDiffTime
safetyBuffer = 15

-- | What a request's lines hold: the questions asked in it, its last worker, and when it last waited.
data Span = Span {asked :: [QId], lastWorker :: Maybe AgentId, pausedAt :: Maybe UTCTime}

emptySpan :: Span
emptySpan = Span [] Nothing Nothing

{- | Each request's span, a line counted in the request in focus as it was
logged, read off what the line changed. A request opens afresh when the
focus moves to one that was not waiting: its number may be one a dropped
request had.
-}
spansOf :: NonEmpty (Envelope, RunState) -> Map TaskNo Span
spansOf ((_, first) :| rest) = snd (foldl' step (first, Map.singleton first.focus emptySpan) rest)
  where
    step (before, spans) (envelope, after) = (after, reopened (Map.alter (Just . noted . fromMaybe emptySpan) before.focus spans))
      where
        noted here =
            here
                { asked = here.asked <> Set.toList (Set.difference after.everAsked before.everAsked)
                , lastWorker = listToMaybe (reverse [worker.agent | worker <- after.workers, worker `notElem` before.workers]) <|> here.lastWorker
                , pausedAt = if Map.member before.focus after.suspended && Map.notMember before.focus before.suspended then Just envelope.ts else here.pausedAt
                }
        reopened
            | after.focus /= before.focus && Map.notMember after.focus before.suspended = Map.insert after.focus emptySpan
            | otherwise = id
