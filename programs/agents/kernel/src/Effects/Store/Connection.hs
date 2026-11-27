{- | The kernel's store: one SQLite database per machine user, holding every
run and its events. @Effects.Store.*@ are the only modules that speak SQL,
and they speak rows only ("Data.Entity").

Open reads the file's header first and refuses a file that is not this
kernel's store, or is a newer kernel's, before anything writes to it
("Effects.Store.Migration"). Then every connection waits up to 5s for
another writer, runs in WAL mode, so readers never block the writer,
enforces foreign keys and runs the delete triggers on @INSERT OR REPLACE@
(@recursive_triggers@), as the DDL's header asks. Last, the projections
are rebuilt if stale ("Effects.Store.Projection").
-}
module Effects.Store.Connection (
    Store (..),
    Durability (..),
    OpenRefusal (..),
    Foreign (..),
    withStore,
) where

import Control.Exception (handle, throwIO)
import Data.Projection (Projections)
import Database.SQLite.Simple (Connection, SQLError, execute_, withConnection)
import Effects.Store.Migration (Foreign (..), OpenRefusal (..), check, migrate)
import Effects.Store.Projection (refresh)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

{- | An open store: one connection, its pragmas set and its schema and
projections current, and the projections each append replaces a run's rows in.
-}
data Store = Store {connection :: Connection, projections :: Projections}

{- | Whether a commit waits for the disk. 'Full' survives an OS crash or a
power loss. 'Unsynced' never fsyncs: a crashed process still loses nothing
committed, but an OS crash can drop writes or corrupt the store. It saves
~4ms a writing process, the checkpoint each last connection's close syncs,
so only the test suite's throwaway stores take it.
-}
data Durability = Full | Unsynced
    deriving stock (Eq, Show)

{- | The store at this path, created with its directory if absent, open for
one action, keeping these projections; or why the file there is not opened.
An SQLite error, such as a lock still held after the wait, throws an 'IOError'.
-}
withStore ::
    Durability ->
    FilePath ->
    Projections ->
    (Store -> IO a) ->
    IO (Either OpenRefusal a)
withStore durability path projections act = do
    createDirectoryIfMissing True (takeDirectory path)
    asIOError . withConnection path $ \conn -> do
        -- The wait first, and it writes nothing: switching to WAL takes a lock another writer may hold.
        execute_ conn "PRAGMA busy_timeout = 5000"
        check path conn >>= \case
            Left refusal -> pure (Left refusal)
            Right _ -> do
                mapM_
                    (execute_ conn)
                    [ "PRAGMA journal_mode = WAL"
                    , synchronous
                    , "PRAGMA foreign_keys = ON"
                    , "PRAGMA recursive_triggers = ON"
                    ]
                migrate path conn
                    >>= traverse (\() -> refresh projections conn >> act (Store conn projections))
  where
    synchronous = case durability of
        Full -> "PRAGMA synchronous = FULL"
        Unsynced -> "PRAGMA synchronous = OFF"
    asIOError =
        handle (\(e :: SQLError) -> throwIO (userError ("the run store: " <> show e)))
