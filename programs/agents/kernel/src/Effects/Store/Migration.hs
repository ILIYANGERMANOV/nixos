{- | The store's schema and its versions. 'check' reads a file's header before
anything writes to it: its @application_id@ says it is this kernel's store,
its @user_version@ how many 'migrations' it applied. A file is new when both
are 0 and it holds no schema object. 'migrate' applies the rest, each once, in
order, under @BEGIN IMMEDIATE@.
-}
module Effects.Store.Migration (
    OpenRefusal (..),
    Foreign (..),
    applicationId,
    latest,
    check,
    migrate,
    dueUnderLock,
    permanent,
) where

import Control.Exception (catch, throwIO)
import Data.Entity.Blob qualified as Blob
import Data.Entity.Event qualified as Event
import Data.Entity.Run qualified as Run
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Table (Table (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Database.SQLite.Simple (
    Connection,
    Only (..),
    SQLError (..),
    query_,
    withImmediateTransaction,
 )
import Database.SQLite.Simple qualified as Simple
import Database.SQLite3 (Error (ErrorNotADatabase), exec)

{- | Why a file is not opened as the store: it is another application's, or
no SQLite database at all, or a newer kernel's schema. Nothing is written to
it first.
-}
data OpenRefusal
    = NotAStateStore FilePath Foreign
    | -- | The file's schema version, and the latest this kernel knows.
      NewerSchema FilePath Int Int
    deriving stock (Eq, Show)

data Foreign = ApplicationId Int64 | NotSQLite
    deriving stock (Eq, Show)

-- | The bytes @KRNL@: the first migration sets it, and open refuses a file without it.
applicationId :: Int64
applicationId = 1263685196

-- | The schema version this kernel writes: the count of its migrations.
latest :: Int
latest = length migrations

{- | How many migrations the file at this path applied (0 when it is new),
or why it is not opened. Reads only.
-}
check :: FilePath -> Connection -> IO (Either OpenRefusal Int)
check path conn = catch (verdict <$> header) notADatabase
  where
    header =
        (,,)
            <$> pragma "PRAGMA application_id"
            <*> pragma "PRAGMA user_version"
            <*> pragma "SELECT count(*) FROM sqlite_schema"
    verdict = \case
        (0, 0, 0) -> Right 0
        (app, applied, _)
            | app /= applicationId -> Left (NotAStateStore path (ApplicationId app))
            | fromIntegral applied > latest ->
                Left (NewerSchema path (fromIntegral applied) latest)
            | otherwise -> Right (fromIntegral applied)
    notADatabase = \case
        SQLError {sqlError = ErrorNotADatabase} -> pure (Left (NotAStateStore path NotSQLite))
        e -> throwIO e
    pragma q =
        query_ conn q >>= \case
            [Only (v :: Int64)] -> pure v
            _ -> throwIO (userError (show q <> " returned no single row"))

{- | Brings the schema to 'latest' from the migrations the file applied, or
refuses it as 'check' does.
-}
migrate :: FilePath -> Connection -> IO (Either OpenRefusal ())
migrate path conn = fromMaybe (Right ()) <$> dueUnderLock conn (due <$> check path conn)
  where
    due = \case
        Left refusal -> Just (pure (Left refusal))
        Right applied
            | applied == latest -> Nothing
            | otherwise ->
                Just (Right () <$ for_ (drop applied (zip [1 :: Int ..] migrations)) apply)
    apply (n, script) = do
        exec (Simple.connectionHandle conn) script
        -- A pragma takes no bound parameter; n is a number this module made.
        exec
            (Simple.connectionHandle conn)
            ("PRAGMA user_version = " <> Text.pack (show n))

{- | What a read finds due, done under the write lock (@BEGIN IMMEDIATE@)
after the same read again there: another process may have done it, or
changed the file, meanwhile. So two processes opening at once do it once.
-}
dueUnderLock :: Connection -> IO (Maybe (IO a)) -> IO (Maybe a)
dueUnderLock conn due =
    due >>= \case
        Nothing -> pure Nothing
        Just _ -> withImmediateTransaction conn (due >>= sequence)

{- | The tables the migrations make, by name: the store's facts. Every other
table and view is a projection, made and dropped by
"Effects.Store.Projection".
-}
permanent :: [Text]
permanent = [t.name | (t, _) <- entities]

-- | The store's facts, each table with its append-only triggers.
entities :: [(Table, [Text])]
entities =
    [ (Run.table, Run.triggers)
    , (Event.table, Event.triggers)
    , (Blob.table, Blob.triggers)
    ]

{- | The migrations, oldest first, each one script; never edit one that
shipped.

1. The kernel-v2 store: @runs@, @events@ and @blobs@, append-only, as issue
   #552's Appendix A has them, and the application id.
-}
migrations :: [Text]
migrations = [v1]

{- | Every table and its indexes, then every trigger, then the application
id. Its text derives from the entities' DDL, as it has not shipped yet:
before the first change to an entity's DDL, freeze it here (copy the
script it makes, literally) and make the change a new migration. Otherwise
a new store would get the new schema under version 1 while an old store
kept the old one.
-}
v1 :: Text
v1 =
    Text.unlines
        [ statement <> ";"
        | statement <-
            concat [t.ddl : t.indexes | (t, _) <- entities] <> concatMap snd entities
        ]
        <> "PRAGMA application_id = "
        <> Text.pack (show applicationId)
        <> ";\n"
