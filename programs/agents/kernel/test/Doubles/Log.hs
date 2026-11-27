{- | Run logs in memory, each run's events as the store keeps them: one
@events@ row each, read and written through the same mapping
("Effects.Log"'s 'decision'), so they fail and read as the real ones do. As
in the store, a run exists once its start is written, events for a run never
started that do not start it throw, and so do events whose seqs do not
follow the log's. The lock is the single-threaded run itself.
-}
module Doubles.Log (Runs (..), runLogInMemory, rowsOf, editRows) where

import Data.Entity.Event (EventRow)
import Data.Entity.Run (RunRow (..))
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe)
import Data.Payload.Event (decodeRow, runRow)
import Data.Payload.Upcast (Upcasts)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Exception (throwIO)
import Effectful.State.Static.Local (State, get, put)
import Effects.Log (Log (..), decision, firstOf)
import Effects.Store.Events (Write (..), misnumbered)
import State.Run.Event (RunId, runIdText)

{- | Each run's rows, in seq order, the runs in the order they started, as
the store's rowid keeps them; read-only, every lock throws, as a full disk or
a lock held past the wait fails the real store's.
-}
data Runs = Runs [(RunId, [EventRow])] | ReadOnly [(RunId, [EventRow])]

runLogInMemory :: (State Runs :> es) => Upcasts -> Eff (Log : es) a -> Eff es a
runLogInMemory upcasts = interpret $ \_ -> \case
    Exists run -> any ((== run) . fst) . rowsOf <$> get
    FirstEvent run -> firstOf upcasts . fromMaybe [] . lookup run . rowsOf <$> get
    Locked run decide -> do
        store <- get
        let runs = rowsOf store
            rows = lookup run runs
            (write, result) = decision upcasts decide (fromMaybe [] rows)
        case (store, rows, write) of
            -- The lock is a write lock, as the real store's BEGIN IMMEDIATE is.
            (ReadOnly _, _, _) -> throwIO (userError "the run store is read-only")
            (Runs _, _, Nothing) -> pure ()
            (Runs _, _, Just new)
                | Just why <- misnumbered (maybe 0 length rows) (written new) ->
                    throwIO (userError why)
            (Runs _, Just _, Just (Append new)) -> put (editRows run (<> toList new) store)
            (Runs _, Nothing, Just (Start _ new)) -> put (Runs (runs <> [(run, toList new)]))
            (Runs _, Nothing, Just (Append _)) -> throwIO (userError "events for a run never started")
            (Runs _, Just _, Just (Start _ _)) -> throwIO (userError "the run was started already")
        pure result
    -- Oldest first, in the order they started, as the store's rowid orders them.
    Children run ->
        ( \runs ->
            [ child
            | (child, rows) <- runs
            , index <- indexOf rows
            , index.parentRunId == Just (runIdText run)
            ]
        )
            . rowsOf
            <$> get
    InNotes notes ->
        ( \runs ->
            [ found
            | (found, rows) <- runs
            , index <- indexOf rows
            , index.notesDir == Text.pack notes
            ]
        )
            . rowsOf
            <$> get
  where
    written = \case
        Append new -> new
        Start _ new -> new :: NonEmpty EventRow
    -- The run's @runs@ row, as the store wrote it from the first row.
    indexOf rows =
        [ index
        | first <- take 1 rows
        , Right e <- [decodeRow upcasts first]
        , index <- toList (runRow e)
        ]

-- | The rows, writable or not.
rowsOf :: Runs -> [(RunId, [EventRow])]
rowsOf = \case
    Runs runs -> runs
    ReadOnly runs -> runs

-- | The run's rows edited by hand, as a store's rows are; the store writable again.
editRows :: RunId -> ([EventRow] -> [EventRow]) -> Runs -> Runs
editRows run edit store =
    Runs
        [ (found, if found == run then edit rows else rows)
        | (found, rows) <- rowsOf store
        ]
