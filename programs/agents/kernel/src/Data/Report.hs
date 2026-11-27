{- | The one part of @state report@ that is not SQL (#552 s9, D12, D24): a
step's rest time, the time of its visits with no span open. The store reads
back the visits and spans ('Visit', 'SpanTime'); 'rests' takes the union of
the spans open inside each visit, so two agents at once count once, and
sums what is left per run and step. The waits report prints it beside the
SQL columns.
-}
module Data.Report (
    Visit (..),
    SpanTime (..),
    Rest (..),
    rests,
    restsJson,
) where

import Data.Int (Int64)
import Data.Json (jsonText)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)

{- | A visit the run has left: its run, its step, and when it began and
ended, in milliseconds since the epoch.
-}
data Visit = Visit {runId :: Text, step :: Text, entered :: Int64, left :: Int64}
    deriving stock (Eq, Show)

{- | A span of a run: when it started, and when it ended, if it did, in
milliseconds since the epoch. One with no end is open until the visit ends.
-}
data SpanTime = SpanTime {runId :: Text, started :: Int64, ended :: Maybe Int64}
    deriving stock (Eq, Show)

-- | The time a run spent at a step with no span open, summed over its visits.
data Rest = Rest {runId :: Text, step :: Text, millis :: Int64}
    deriving stock (Eq, Show)

-- | Each run and step's rest over these visits, in run and step order.
rests :: [Visit] -> [SpanTime] -> [Rest]
rests visits spans =
    [ Rest run step millis
    | ((run, step), millis) <-
        Map.toList
            ( Map.fromListWith
                (+)
                [ ((visit.runId, visit.step), restOf visit (spansOf visit.runId))
                | visit <- visits
                ]
            )
    ]
  where
    byRun = Map.fromListWith (<>) [(s.runId, [s]) | s <- spans]
    spansOf run = Map.findWithDefault [] run byRun

{- | A visit's length less the union of the spans open inside it, each
clipped to the visit.
-}
restOf :: Visit -> [SpanTime] -> Int64
restOf visit spans = (visit.left - visit.entered) - covered (sortOn fst inside)
  where
    inside =
        [ (max s.started visit.entered, end)
        | s <- spans
        , let end = min visit.left (fromMaybe visit.left s.ended)
        , max s.started visit.entered < end
        ]

-- | The length of the union of intervals sorted by their start.
covered :: [(Int64, Int64)] -> Int64
covered = \case
    [] -> 0
    (start, end) : rest -> go start end rest
  where
    go start end = \case
        [] -> end - start
        (s, e) : rest
            | s <= end -> go start (max end e) rest
            | otherwise -> (end - start) + go s e rest

{- | The rests as a JSON array of @[run_id, step, milliseconds]@, as the
waits report's SQL reads them with @json_each@, so SQLite spells the seconds.
-}
restsJson :: [Rest] -> Text
restsJson =
    jsonText . map (\r -> (r.runId, r.step, r.millis))
