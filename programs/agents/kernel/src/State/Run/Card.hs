{- | A chief's requests as cards, read off its log: where each stands, what
was decided in it and what it still asks. Derived, never stored: the log
line by line ('State.Run.Fold.trace') says which request each line was
logged in.
-}
module State.Run.Card (
    Card (..),
    Standing (..),
    cards,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Time (UTCTime)
import State.Run.Ask (Kind, OneLine, QId, Question (..), Reply)
import State.Run.Event (Asking (..), Envelope (..), StateName, TaskNo)
import State.Run.Fold (
    Pending (..),
    RunState (..),
    Suspension (..),
    given,
    nodeName,
    waitsAt,
 )

-- | A request: its number, whether it waits, its state, its decisions and open questions.
data Card = Card
    { task :: TaskNo
    , standing :: Standing
    , node :: StateName
    , decisions :: [(QId, Kind, Reply)]
    , open :: [Question]
    }
    deriving stock (Eq, Show)

-- | In focus, or waiting since the line that suspended it, where it stood in the lead's words.
data Standing = InFocus | Paused UTCTime OneLine
    deriving stock (Eq, Show)

{- | The card of each request open in the run: the one in focus, then each
waiting one, by number.
-}
cards :: NonEmpty (Envelope, RunState) -> [Card]
cards logged =
    cardOf InFocus final.focus (nodeName final.at)
        : [ cardOf (Paused at suspension.summary) task (nodeName (waitsAt suspension))
          | (task, suspension) <- Map.toList final.suspended
          , Just at <- [(spanOf task).pausedAt]
          ]
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
                , decisions =
                    [decision | decision@(qid, _, _) <- given final, qid `elem` here.asked]
                , open =
                    [ p.asking.question | p <- final.pending, p.asking.question.qid `elem` here.asked
                    ]
                }

-- | What a request's lines hold: the questions asked in it, and when it last waited.
data Span = Span {asked :: [QId], pausedAt :: Maybe UTCTime}

emptySpan :: Span
emptySpan = Span [] Nothing

{- | Each request's span, a line counted in the request in focus as it was
logged, read off what the line changed. A request opens afresh when the
focus moves to one that was not waiting: its number may be one a dropped
request had.
-}
spansOf :: NonEmpty (Envelope, RunState) -> Map TaskNo Span
spansOf ((_, first) :| rest) = snd (foldl' step (first, Map.singleton first.focus emptySpan) rest)
  where
    step (before, spans) (envelope, after) =
        ( after
        , reopened (Map.alter (Just . noted . fromMaybe emptySpan) before.focus spans)
        )
      where
        noted here =
            here
                { asked =
                    here.asked <> Set.toList (Set.difference after.everAsked before.everAsked)
                , pausedAt =
                    if Map.member before.focus after.suspended
                        && Map.notMember before.focus before.suspended
                        then Just envelope.ts
                        else here.pausedAt
                }
        reopened
            | after.focus /= before.focus && Map.notMember after.focus before.suspended =
                Map.insert after.focus emptySpan
            | otherwise = id
