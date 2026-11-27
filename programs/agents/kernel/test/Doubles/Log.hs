{- | Run logs in memory, each run's events as the store keeps them: one
@events@ row each, read and written through the same mapping
("Effects.Log"'s 'decision'), so they fail and read as the real ones do. As
in the store, a run exists once its start is written, with the @runs@ row
that start gives, and its children and notes are read from that row alone.
Events for a run never started that do not start it throw, and so do events
whose seqs do not follow the log's or whose hook digest the run holds
already. Blobs are the store's, not a run's: one per key, the first kept.
The lock is the single-threaded run itself.
-}
module Doubles.Log (
    Runs,
    Access (..),
    noRuns,
    withAccess,
    runLogInMemory,
    rowsOf,
    editRows,
    written,
) where

import Data.Containers.ListUtils (nubOrd)
import Data.Entity.Blob (BlobRow (..))
import Data.Entity.Event (EventRow (..))
import Data.Entity.Run (RunRow (..))
import Data.Field qualified as Field
import Data.Foldable (for_, toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Payload.Event (dumpLine)
import Data.Payload.Upcast (Upcasts)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Exception (throwIO)
import Effectful.State.Static.Local (State, get, put)
import Effects.Log (Log (..), blobRead, decision, firstOf, loggedUntil)
import Effects.Store.Events (Batch (..), Write (..), misnumbered)
import State.Run.Event (RunId, runIdText)

{- | Each run as the store keeps it, in the order they started, as the
store's rowid keeps them, and the store's blobs by key.
-}
data Runs = Runs Access [(RunId, Kept)] (Map Text BlobRow)

{- | Whether the store takes writes: read-only, every lock throws, as a full
disk or a lock held past the wait fails the real store's.
-}
data Access = Writable | ReadOnly

-- | A run's @runs@ row as its start wrote it, and its rows in seq order.
data Kept = Kept {index :: RunRow, rows :: [EventRow]}

-- | A writable store with no run.
noRuns :: Runs
noRuns = Runs Writable [] Map.empty

-- | The same runs, writable or not.
withAccess :: Access -> Runs -> Runs
withAccess access (Runs _ kept blobs) = Runs access kept blobs

runLogInMemory :: (State Runs :> es) => Upcasts -> Eff (Log : es) a -> Eff es a
runLogInMemory upcasts = interpret $ \_ -> \case
    Exists run -> any ((== run) . fst) . rowsOf <$> get
    FirstEvent run -> firstOf upcasts . rowsIn run <$> get
    Rows run -> map dumpLine . rowsIn run <$> get
    ReadUntil run k -> loggedUntil upcasts k . rowsIn run <$> get
    Locked run decide ->
        get >>= \case
            -- The lock is a write lock, as the real store's BEGIN IMMEDIATE is.
            Runs ReadOnly _ _ -> throwIO (userError "the run store is read-only")
            store@(Runs Writable _ _) -> do
                let (write, result) = decision upcasts decide (rowsIn run store)
                for_ write $ \new -> either (throwIO . userError) put (written run new store)
                pure result
    ReadBlob key ->
        get >>= \(Runs _ _ blobs) ->
            either
                (throwIO . userError)
                pure
                (blobRead key (Map.lookup (Field.encode Field.sha256 key) blobs))
    Children run -> indexed (\index -> index.parentRunId == Just (runIdText run)) <$> get
    InNotes notes -> indexed (\index -> index.notesDir == Text.pack notes) <$> get

-- | The rows of every run.
rowsOf :: Runs -> [(RunId, [EventRow])]
rowsOf (Runs _ kept _) = [(run, k.rows) | (run, k) <- kept]

-- | The run's rows edited by hand, as a store's rows are; its @runs@ row kept, the store writable again.
editRows :: RunId -> ([EventRow] -> [EventRow]) -> Runs -> Runs
editRows run edit (Runs _ kept blobs) =
    Runs
        Writable
        [ (found, if found == run then k {rows = edit k.rows} else k)
        | (found, k) <- kept
        ]
        blobs

{- | The store with this batch to the run, as the store's own append writes
it under the lock, the store writable again; or why the store refuses it,
as its constraints do. A blob whose key is stored already is left as it is.
-}
written :: RunId -> Batch -> Runs -> Either String Runs
written run Batch {write, blobs = new} (Runs _ kept blobs) = case (lookup run kept, write) of
    (Nothing, Start index rows) ->
        (\logged -> Runs Writable (kept <> [(run, Kept index logged)]) stored)
            <$> appended [] rows
    (Just k, Append rows) ->
        (\logged -> editRows run (const logged) (Runs Writable kept stored))
            <$> appended k.rows rows
    (Nothing, Append _) -> Left "events for a run never started"
    (Just _, Start _ _) -> Left "the run was started already"
  where
    -- Map.union keeps the left one: the blob stored first.
    stored = Map.union blobs (Map.fromList [(row.sha256, row) | row <- new])

-- | The run's rows with these after them, held to the store's keys: seq and hook digest.
appended :: [EventRow] -> NonEmpty EventRow -> Either String [EventRow]
appended logged new = case misnumbered (length logged) new of
    Just why -> Left why
    Nothing
        | length (nubOrd digests) /= length digests ->
            Left "UNIQUE constraint failed: events.run_id, events.hook_digest"
        | otherwise -> Right whole
  where
    whole = logged <> toList new
    digests = mapMaybe (.hookDigest) whole

rowsIn :: RunId -> Runs -> [EventRow]
rowsIn run = fromMaybe [] . lookup run . rowsOf

-- | The runs whose @runs@ row holds, oldest first, as the store's rowid orders them.
indexed :: (RunRow -> Bool) -> Runs -> [RunId]
indexed holds (Runs _ kept _) = [run | (run, k) <- kept, holds k.index]
