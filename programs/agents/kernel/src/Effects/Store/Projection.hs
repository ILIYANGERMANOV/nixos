{- | The projection tables in the store (#552): replaced for a run in each
append's transaction ('replace'), and rebuilt whole at an open that finds
them stale ('refresh'). Rows come from the pure 'Projections' the caller
builds; this module only runs their SQL.

Both delete and insert with @defer_foreign_keys@ on: a row's parent may come
after it, and SQLite checks the keys at commit, so no table order is kept.
-}
module Effects.Store.Projection (
    refresh,
    replace,
    insert,
) where

import Control.Monad (void)
import Data.Entity.Event (EventRow)
import Data.Foldable (for_, toList)
import Data.Int (Int64)
import Data.Projection (
    Insert (..),
    Projection (..),
    Projections (..),
    Table (..),
    Value (..),
    strictTable,
 )
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.SQLite.Simple (
    Connection,
    Only (..),
    Query (..),
    SQLData (..),
    execute,
    executeMany,
    execute_,
    query,
    query_,
 )
import Effects.Store.EventRows (selectRows)
import Effects.Store.Migration (dueUnderLock, permanent)

{- | At open, after the migrations: when any projection's DDL differs from
what @sqlite_schema@ holds, or its version from
@projection_versions@, drop every projection, make them all anew and refold
every run. The whole set, as one projection's rows may reference another's.
A version differing either way rebuilds, so an older kernel rebuilds too.
-}
refresh :: Projections -> Connection -> IO ()
refresh ps conn = void (dueUnderLock conn (due <$> current ps conn))
  where
    due = \case
        True -> Nothing
        False -> Just (rebuild ps conn)

{- | The run's rows in every projection, replaced by those its event rows
fold to: none when they do not fold. Called inside the append's transaction.
-}
replace :: Projections -> Connection -> Text -> [EventRow] -> IO ()
replace ps conn run logged = do
    execute_ conn "PRAGMA defer_foreign_keys = ON"
    -- Every projection table has the run's id in its run_id column.
    for_ (tableNames ps.projections) $ \table ->
        execute conn (Query ("DELETE FROM " <> table <> " WHERE run_id = ?")) (Only run)
    for_ (ps.refold logged) (insert conn)

-- | One row into its table.
insert :: Connection -> Insert -> IO ()
insert conn row =
    execute
        conn
        ( Query
            ( "INSERT INTO "
                <> row.table
                <> " ("
                <> Text.intercalate ", " (map fst values)
                <> ") VALUES ("
                <> Text.intercalate ", " ("?" <$ values)
                <> ")"
            )
        )
        (map (sqlData . snd) values)
  where
    values = toList row.values

sqlData :: Value -> SQLData
sqlData = \case
    SqlText t -> SQLText t
    SqlInteger i -> SQLInteger i
    SqlNull -> SQLNull

-- | Whether the stored projections are these, DDL and versions alike.
current :: Projections -> Connection -> IO Bool
current ps conn = do
    stored <-
        query_ conn "SELECT tbl_name, sql FROM sqlite_schema WHERE sql IS NOT NULL"
    if Set.fromList [sql | (table, sql) <- stored, table `notElem` permanent]
        /= Set.fromList (ddls ps)
        then pure False
        else
            (== Set.fromList [(p.name, fromIntegral p.version) | p <- ps.projections])
                . Set.fromList
                <$> ( query_ conn "SELECT name, version FROM projection_versions" ::
                        IO [(Text, Int64)]
                    )

rebuild :: Projections -> Connection -> IO ()
rebuild ps conn = do
    execute_ conn "PRAGMA defer_foreign_keys = ON"
    views <- names "view"
    tables <- names "table"
    for_ views $ \view -> execute_ conn (Query ("DROP VIEW " <> quoted view))
    for_ [table | table <- tables, table `notElem` permanent] $ \table ->
        execute_ conn (Query ("DROP TABLE " <> quoted table))
    for_ (ddls ps) (execute_ conn . Query)
    executeMany
        conn
        "INSERT INTO projection_versions (name, version) VALUES (?, ?)"
        [(p.name, fromIntegral p.version :: Int64) | p <- ps.projections]
    runs <- query_ conn "SELECT id FROM runs ORDER BY rowid"
    for_ runs $ \(Only run) -> selectRows conn run >>= mapM_ (insert conn) . ps.refold
  where
    names :: Text -> IO [Text]
    names kind =
        map fromOnly
            <$> query
                conn
                "SELECT name FROM sqlite_schema WHERE type = ? AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
                (Only kind)
    quoted name = "\"" <> Text.replace "\"" "\"\"" name <> "\""

{- | Every statement that makes the projections, @projection_versions@
first, each table's indexes after it, and the views last, as they read the
tables.
-}
ddls :: Projections -> [Text]
ddls ps =
    versionsDdl
        : [ statement
          | p <- ps.projections
          , t <- toList p.tables
          , statement <- t.ddl : t.indexes
          ]
            <> ps.views

tableNames :: [Projection] -> [Text]
tableNames projections = [t.name | p <- projections, t <- toList p.tables]

-- | @projection_versions@, as SQLite stores its statement.
versionsDdl :: Text
versionsDdl =
    ( strictTable
        "projection_versions"
        [ "  -- One row per projection module. Every projection is dropped, recreated and refolded"
        , "  -- when any one's DDL text differs from sqlite_schema.sql, or its version here from the kernel's."
        , ""
        , "  -- The projection module's name, such as tasks or questions."
        , "  name    TEXT    NOT NULL PRIMARY KEY,"
        , "  -- The version of the module's rows function, from 1. Bumped by hand when the rows change."
        , "  version INTEGER NOT NULL"
        , "          CONSTRAINT projection_versions_version_positive CHECK (version >= 1)"
        ]
    ).ddl
