{- | The store's schema as SQLite holds it: Appendix A's text, each named
CHECK refusing its bad row, each append-only trigger aborting every way to
change a row, and an open that refuses a file not this kernel's.
-}
module Effects.Store.MigrationSpec (spec) where

import Control.Exception (try)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as Text
import Database.SQLite.Simple (
    Connection,
    Only (..),
    SQLError (..),
    execute_,
    query_,
    withConnection,
 )
import Database.SQLite.Simple qualified as SQLite
import Effects.Store.Connection (
    Durability (Unsynced),
    Foreign (..),
    OpenRefusal (..),
    Store (..),
    withStore,
 )
import State.Golden (golden)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldReturn,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "Effects.Store.Migration" $ do
    schema <-
        runIO . withSystemTempDirectory "state-store" $ \dir ->
            onStore dir $ \conn ->
                query_ conn "SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY rowid"
    it "creates the schema Appendix A states, as SQLite keeps it" $
        golden "schema-v2.sql" (Text.unlines [sql <> ";" | Only sql <- schema])

    it "marks a new store with the application id and the schema version" $
        withSystemTempDirectory "state-store" $ \dir ->
            onStore
                dir
                (\conn -> (,) <$> pragma conn "application_id" <*> pragma conn "user_version")
                `shouldReturn` (1263685196, 1)

    describe "refuses each bad row by its CHECK's name" $
        for_ badRows $ \(name, statement) ->
            it name $ withSystemTempDirectory "state-store" $ \dir -> do
                refused <- onStore dir (\conn -> seeded conn >> try (execute_ conn statement))
                refused
                    `shouldSatisfy` refusedWith ("CHECK constraint failed: " <> Text.pack name)

    describe "aborts every change to a row with its table's trigger" $
        for_ changes $ \(table, how, statement, message) ->
            it (Text.unpack table <> ": " <> how) $ withSystemTempDirectory "state-store" $ \dir -> do
                refused <- onStore dir (\conn -> seeded conn >> try (execute_ conn statement))
                refused `shouldSatisfy` refusedWith message

    describe
        "refuses to open a file that is not this kernel's store, writing nothing to it"
        $ do
            it "another application's database" $
                withSystemTempDirectory "state-store" $ \dir -> do
                    let path = dir </> "other.db"
                    withConnection path (`execute_` "PRAGMA application_id = 42")
                    untouched path (withStore Unsynced path (const (pure ())))
                        `shouldReturn` Left (NotAStateStore path (ApplicationId 42))

            it "a newer kernel's store" $
                withSystemTempDirectory "state-store" $ \dir -> do
                    let path = dir </> "newer.db"
                    withConnection path $ \conn ->
                        mapM_
                            (execute_ conn)
                            ["PRAGMA application_id = 1263685196", "PRAGMA user_version = 2"]
                    untouched path (withStore Unsynced path (const (pure ())))
                        `shouldReturn` Left (NewerSchema path 2 1)

            it "a file that is no SQLite database" $
                withSystemTempDirectory "state-store" $ \dir -> do
                    let path = dir </> "notes.txt"
                    BS.writeFile path (BS.replicate 4096 0x61)
                    untouched path (withStore Unsynced path (const (pure ())))
                        `shouldReturn` Left (NotAStateStore path NotSQLite)

-- | The action's result, failing the example when it changed the file's bytes.
untouched :: FilePath -> IO a -> IO a
untouched path act = do
    before <- BS.readFile path
    result <- act
    after <- BS.readFile path
    if after == before
        then pure result
        else result <$ expectationFailure "the file changed"

-- | An action on a new store's connection, its pragmas set as every open sets them.
onStore :: FilePath -> (Connection -> IO a) -> IO a
onStore dir act =
    withStore Unsynced (dir </> "kernel-v2.db") (\(Store conn) -> act conn)
        >>= either (fail . show) pure

pragma :: Connection -> Text -> IO Int
pragma conn name =
    query_ conn (SQLite.Query ("PRAGMA " <> name)) >>= \case
        [Only v] -> pure v
        _ -> fail "no single row"

refusedWith :: Text -> Either SQLError () -> Bool
refusedWith message = \case
    Left e -> message `Text.isInfixOf` e.sqlErrorDetails
    Right () -> False

-- | One good row in each table, for the changes to touch.
seeded :: Connection -> IO ()
seeded conn =
    mapM_
        (execute_ conn)
        [ "INSERT INTO runs (id, flow, notes_dir, created_at) VALUES ('r1', 'engineer', '/n', '2026-11-13T00:00:00.000Z')"
        , "INSERT INTO events (run_id, seq, schema_version, type, time, data) VALUES ('r1', 1, 1, 'started', '2026-11-13T00:00:00.000Z', '{}')"
        , SQLite.Query
            ( "INSERT INTO blobs (sha256, size_bytes, content) VALUES ('"
                <> sha64
                <> "', 1, x'61')"
            )
        ]

-- | Each named CHECK of Appendix A's probe and a row it refuses.
badRows :: [(String, SQLite.Query)]
badRows =
    [ ("runs_id_format", run "'r:2'" "NULL" "'2026-11-13T00:00:00.000Z'")
    , ("runs_parent_run_id_not_self", run "'r2'" "'r2'" "'2026-11-13T00:00:00.000Z'")
    , ("runs_created_at_format", run "'r2'" "NULL" "'2026-11-13T00:00:00Z'")
    ,
        ( "events_seq_positive"
        , event "0" "1" "'t'" "'2026-11-13T00:00:00.000Z'" "NULL" "NULL" "NULL" "'{}'"
        )
    ,
        ( "events_schema_version_positive"
        , event "2" "0" "'t'" "'2026-11-13T00:00:00.000Z'" "NULL" "NULL" "NULL" "'{}'"
        )
    ,
        ( "events_type_not_empty"
        , event "2" "1" "''" "'2026-11-13T00:00:00.000Z'" "NULL" "NULL" "NULL" "'{}'"
        )
    ,
        ( "events_time_format"
        , event "2" "1" "'t'" "'2026-11-13T23:59:60.000Z'" "NULL" "NULL" "NULL" "'{}'"
        )
    ,
        ( "events_session_id_not_empty"
        , event "2" "1" "'t'" "'2026-11-13T00:00:00.000Z'" "''" "NULL" "NULL" "'{}'"
        )
    ,
        ( "events_head_sha_format"
        , event "2" "1" "'t'" "'2026-11-13T00:00:00.000Z'" "NULL" "'abc123'" "NULL" "'{}'"
        )
    ,
        ( "events_hook_digest_format"
        , event
            "2"
            "1"
            "'t'"
            "'2026-11-13T00:00:00.000Z'"
            "NULL"
            "NULL"
            "'af63dc4c8601ec8'"
            "'{}'"
        )
    ,
        ( "events_data_json_object"
        , event "2" "1" "'t'" "'2026-11-13T00:00:00.000Z'" "NULL" "NULL" "NULL" "'[1]'"
        )
    ,
        ( "blobs_sha256_format"
        , "INSERT INTO blobs (sha256, size_bytes, content) VALUES ('ABC', 1, x'61')"
        )
    ,
        ( "blobs_size_bytes_matches_content"
        , SQLite.Query
            ( "INSERT INTO blobs (sha256, size_bytes, content) VALUES ('"
                <> sha64
                <> "', 2, x'61')"
            )
        )
    ]
  where
    run i parent at =
        "INSERT INTO runs (id, parent_run_id, flow, notes_dir, created_at) VALUES ("
            <> i
            <> ", "
            <> parent
            <> ", 'engineer', '/n', "
            <> at
            <> ")"
    event n version kind at session sha digest payload =
        "INSERT INTO events (run_id, seq, schema_version, type, time, session_id, head_sha, hook_digest, data) VALUES ('r1', "
            <> SQLite.Query
                (Text.intercalate ", " [n, version, kind, at, session, sha, digest, payload])
            <> ")"

-- | Every way to change a stored row, on each table, and its trigger's message.
changes :: [(Text, String, SQLite.Query, Text)]
changes =
    concat
        [ table
            "runs"
            "id = 'r1'"
            "flow = 'x'"
            "('r1', NULL, 'engineer', '/n', '2026-11-13T00:00:00.000Z')"
            "(id, parent_run_id, flow, notes_dir, created_at)"
            "(id)"
            ("a run never changes", "a run is never deleted")
        , table
            "events"
            "seq = 1"
            "type = 'x'"
            "(1, 'r1', 1, 1, 'started', '2026-11-13T00:00:00.000Z', NULL, NULL, NULL, '{}')"
            "(position, run_id, seq, schema_version, type, time, session_id, head_sha, hook_digest, data)"
            "(position)"
            ("log a new event", "void a line with state void")
        , table
            "blobs"
            "1"
            "size_bytes = 1"
            ("('" <> sha64 <> "', 1, x'61')")
            "(sha256, size_bytes, content)"
            "(sha256)"
            ("new content is a new row", "content is never deleted")
        ]
  where
    table name at set row columns key (updated, deleted) =
        let q = SQLite.Query
         in [
                ( name
                , "UPDATE"
                , q ("UPDATE " <> name <> " SET " <> set <> " WHERE " <> at)
                , updated
                )
            , (name, "DELETE", q ("DELETE FROM " <> name), deleted)
            ,
                ( name
                , "INSERT OR REPLACE"
                , q ("INSERT OR REPLACE INTO " <> name <> " " <> columns <> " VALUES " <> row)
                , deleted
                )
            ,
                ( name
                , "an upsert"
                , q
                    ( "INSERT INTO "
                        <> name
                        <> " "
                        <> columns
                        <> " VALUES "
                        <> row
                        <> " ON CONFLICT "
                        <> key
                        <> " DO UPDATE SET "
                        <> set
                    )
                , updated
                )
            ]

sha64 :: Text
sha64 = Text.replicate 64 "a"
