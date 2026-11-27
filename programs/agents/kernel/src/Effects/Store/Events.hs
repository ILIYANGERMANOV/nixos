{- | The store's runs and events, read and appended as rows. Every write runs
in an immediate transaction (@BEGIN IMMEDIATE@): a read-decide-append takes
the write lock before it reads, so two processes never number an event alike.
Each row's columns are its entity's ("Data.Entity").
-}
module Effects.Store.Events (
    Write (..),
    Batch (..),
    exists,
    rows,
    locked,
    blob,
    misnumbered,
    children,
    inNotes,
) where

import Control.Exception (throwIO)
import Data.Entity.Blob (BlobRow (..), blobInsert)
import Data.Entity.Event (EventRow (..), eventInsert)
import Data.Entity.Run (RunRow, runInsert)
import Data.Foldable (for_, toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.SQLite.Simple (
    Connection,
    Only (..),
    Query,
    query,
    withImmediateTransaction,
 )
import Effects.Store.Connection (Store (..))
import Effects.Store.EventRows (selectRows)
import Effects.Store.Projection (insert, replace)

{- | What a decision appends: events to a started run, or a run's start, its
@runs@ row with its first events. A @runs@ row without its event 1 is no
write.
-}
data Write = Append (NonEmpty EventRow) | Start RunRow (NonEmpty EventRow)
    deriving stock (Eq, Show)

{- | A write and the blobs its events' file artifacts snapshot, in one
transaction: a blob rides only with events, never alone.
-}
data Batch = Batch {write :: Write, blobs :: [BlobRow]}
    deriving stock (Eq, Show)

-- | Whether the run was started in the store.
exists :: Store -> Text -> IO Bool
exists (Store conn _) run =
    not . null
        <$> (query conn "SELECT 1 FROM runs WHERE id = ?" (Only run) :: IO [Only Int])

-- | The run's rows, in seq order, read in one statement, without the write lock.
rows :: Store -> Text -> IO [EventRow]
rows (Store conn _) = selectRows conn

{- | The run's rows, in seq order, under the write lock for one decision:
@decide@ gets them all and returns what to write. Events for a run never
started violate a foreign key and throw, as do events whose seqs do not
follow the log's ('misnumbered'). A blob already stored is kept as it is:
its key is its content's digest, so the content is the same. A write
replaces the run's projection rows, in the same transaction.
-}
locked :: Store -> Text -> ([EventRow] -> (Maybe Batch, a)) -> IO a
locked (Store conn projections) run decide = withImmediateTransaction conn $ do
    logged <- selectRows conn run
    let (batch, result) = decide logged
    for_ batch $ \Batch {write, blobs} -> do
        for_ blobs (insert conn . blobInsert)
        writing (length logged) write
        replace projections conn run (logged <> toList (rowsOf write))
    pure result
  where
    writing count = \case
        Append new -> append count new
        Start start new -> do
            insert conn (runInsert start)
            append count new
    rowsOf = \case
        Append new -> new
        Start _ new -> new
    append count new = do
        for_ (misnumbered count new) (throwIO . userError)
        for_ new (insert conn . eventInsert)

-- | The blob stored under this key, if any.
blob :: Store -> Text -> IO (Maybe BlobRow)
blob (Store conn _) key =
    listToMaybe . map blobRow
        <$> query
            conn
            "SELECT sha256, size_bytes, content FROM blobs WHERE sha256 = ?"
            (Only key)
  where
    blobRow (sha256, sizeBytes, content) = BlobRow {sha256, sizeBytes, content}

{- | Why these rows cannot follow a log of this many: seqs run densely from
1, so a duplicate or a gap is a writer's bug. The unique key alone refuses
only the duplicate.
-}
misnumbered :: Int -> NonEmpty EventRow -> Maybe String
misnumbered count new = case [ (row.seq, next)
                             | (row, next) <- zip (toList new) [fromIntegral count + 1 ..]
                             , row.seq /= next
                             ] of
    [] -> Nothing
    (got, next) : _ ->
        Just
            ( "seq "
                <> show got
                <> " where "
                <> show next
                <> " is next: a log's seqs run densely from 1"
            )

{- | The runs started as children of this one, oldest first: in the order
their starts were written, the rowid's, as two in one millisecond tie on
@created_at@.
-}
children :: Store -> Text -> IO [Text]
children (Store conn _) =
    ids conn "SELECT id FROM runs WHERE parent_run_id = ? ORDER BY rowid"

-- | The runs started in this notes dir, oldest first, as 'children' orders them.
inNotes :: Store -> Text -> IO [Text]
inNotes (Store conn _) =
    ids conn "SELECT id FROM runs WHERE notes_dir = ? ORDER BY rowid"

ids :: Connection -> Query -> Text -> IO [Text]
ids conn sql key = map fromOnly <$> query conn sql (Only key)
