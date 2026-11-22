{- | Run logs in memory, each run's events as the store keeps them: one JSON
envelope per row, read and appended through the same codec, so they fail and
read as the real ones do. As in the store, a run exists once its start is
written, events for a run never started that do not start it throw, and so
do events whose seqs do not follow the log's. The lock is the
single-threaded run itself.
-}
module Doubles.Log (Runs (..), runLogInMemory, rowsOf, editRows) where

import Control.Monad ((<=<))
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Exception (throwIO)
import Effectful.State.Static.Local (State, get, put)
import Effects.Log (Log (..))
import Effects.Store (misnumbered)
import State.Run.Codec (decodeLines, encodeLine)
import State.Run.Event (
    Envelope (..),
    Event (..),
    Parent (..),
    Principal (..),
    RunId,
    Start (..),
 )

{- | Each run's rows, in seq order, the runs in the order they started, as
the store's rowid keeps them; read-only, every lock throws, as a full disk or
a lock held past the wait fails the real store's.
-}
data Runs = Runs [(RunId, [Text])] | ReadOnly [(RunId, [Text])]

runLogInMemory :: (State Runs :> es) => Eff (Log : es) a -> Eff es a
runLogInMemory = interpret $ \_ -> \case
    Exists run -> any ((== run) . fst) . rowsOf <$> get
    FirstLine run -> (listToMaybe <=< lookup run) . rowsOf <$> get
    Locked run decide -> do
        store <- get
        let runs = rowsOf store
            rows = lookup run runs
            (new, result) = decide (decodeLines (fromMaybe [] rows))
            appended = map encodeLine new
        case (store, rows, new) of
            -- The lock is a write lock, as the real store's BEGIN IMMEDIATE is.
            (ReadOnly _, _, _) -> throwIO (userError "the run store is read-only")
            (_, _, []) -> pure ()
            (Runs _, _, _ : _) | Just why <- misnumbered (maybe 0 length rows) new -> throwIO (userError why)
            (Runs _, Just _, _ : _) -> put (editRows run (<> appended) store)
            (Runs _, Nothing, Envelope {seq = 1, event = Started _} : _) -> put (Runs (runs <> [(run, appended)]))
            (Runs _, Nothing, _ : _) -> throwIO (userError "events for a run never started")
        pure result
    -- Oldest first, in the order they started, as the store's rowid orders them.
    Children run ->
        ( \runs ->
            [ child
            | (child, rows) <- runs
            , started <- startOf rows
            , parentOf started == Just run
            ]
        )
            . rowsOf
            <$> get
    InNotes notes ->
        ( \runs ->
            [ found
            | (found, rows) <- runs
            , Envelope {event = Started start} <- startOf rows
            , start.notes == notes
            ]
        )
            . rowsOf
            <$> get

-- | The run's first line, when it reads.
startOf :: [Text] -> [Envelope]
startOf rows = case decodeLines (take 1 rows) of
    Right [started] -> [started]
    Right _ -> []
    Left _ -> []

-- | The parent run a start names, if any.
parentOf :: Envelope -> Maybe RunId
parentOf started = case started.event of
    Started start -> case start.principal of
        ByRole parent _ _ -> Just parent.run
        ByUser _ -> Nothing
        ByCaller _ -> Nothing
    _ -> Nothing

-- | The rows, writable or not.
rowsOf :: Runs -> [(RunId, [Text])]
rowsOf = \case
    Runs runs -> runs
    ReadOnly runs -> runs

-- | The run's rows edited by hand, as a store's rows are; the store writable again.
editRows :: RunId -> ([Text] -> [Text]) -> Runs -> Runs
editRows run edit store =
    Runs
        [ (found, if found == run then edit rows else rows)
        | (found, rows) <- rowsOf store
        ]
