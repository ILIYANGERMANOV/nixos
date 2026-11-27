{- | Every projection the store keeps, each with its rows function: a new
group of tables is one module under "Data.Projection" and one entry in
'groups'. A run's rows in all of them come from one trace of its log.
-}
module Data.Projection.Registry (projections, rows) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Projection (Insert, Projection)
import Data.Projection.Questions qualified as Questions
import Data.Projection.Runs qualified as Runs
import Data.Projection.Tasks qualified as Tasks
import State.Role (graphOf)
import State.Run.Event (Envelope (..), Start (..))
import State.Run.Fold (RunState, runStart, trace)

groups :: [(Projection, NonEmpty (Envelope, RunState) -> [Insert])]
groups =
    [ (Runs.projection, Runs.rows)
    , (Tasks.projection, Tasks.rows)
    , (Questions.projection, Questions.rows)
    ]

projections :: [Projection]
projections = map fst groups

{- | A run's rows in every projection, from its log as the fold reads it,
under the flow its first line starts: none for a log the fold refuses.
-}
rows :: NonEmpty Envelope -> [Insert]
rows logged@(first :| _) = case runStart first.event of
    Nothing -> []
    Just start -> case trace (graphOf start.flow) logged of
        Left _ -> []
        Right lines' -> concatMap (\(_, rowsOf) -> rowsOf lines') groups
