{- | The projections in a real store: made at open as SQLite keeps their
DDL, rebuilt whole and once when stale, replaced in each append to the rows
a full rebuild makes, which are the rows the fold makes.
-}
module Effects.Store.ProjectionSpec (spec) where

import Concurrently (bothAtOnce)
import Control.Exception (try)
import Data.Foldable (for_, toList, traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Payload.Event (eventRow, runRow)
import Data.Payload.Upcast (shipped)
import Data.Projection (
    Insert (..),
    Projection (..),
    Projections (..),
    Table (..),
    Value (..),
 )
import Data.Projection.Registry qualified as Registry
import Data.Projection.Runs (
    LoopRoundRow (..),
    ProblemKind,
    RoundProblemRow (..),
    RunStateRow (..),
    RunStatus (..),
    StepVisitRow (..),
    loopRoundInsert,
    roundProblemInsert,
    runStateInsert,
    stepVisitInsert,
 )
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple (
    Connection,
    Only (..),
    SQLError (..),
    execute_,
    query_,
 )
import Database.SQLite.Simple qualified as SQLite
import Effects.Log (projected)
import Effects.Store.Connection (Durability (Unsynced), Store (..), withStore)
import Effects.Store.Events (Batch (..), Write (..))
import Effects.Store.Events qualified as Store
import Effects.Store.Projected (Row, inserted, projectionRows)
import Effects.Store.Projection (insert)
import Hedgehog (assert, cover, evalIO, forAll, (===))
import Numeric.Natural (Natural)
import State.Category.Fuel (Fuel (Balanced))
import State.Golden (golden)
import State.Run.Event (Envelope (..), Event, Stop (..), runIdText)
import State.Run.EventGen (fuelSet, line, run, started)
import State.Run.RunGen (genAccepted, happyPath)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, runIO, shouldReturn, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)

spec :: Spec
spec = describe "Effects.Store.Projection" $ do
    schema <-
        runIO . withSystemTempDirectory "state-store" $ \dir -> do
            opened dir shippedProjections (const (pure ()))
            raw
                dir
                (`query_` "SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY rowid")
    it
        "makes every projection at open, beside the migrations' tables, as SQLite keeps them"
        $ golden "schema-open.sql" (Text.unlines [sql <> ";" | Only sql <- schema])

    it
        "writes each projection's DDL as SQLite stores it: a second open changes no schema"
        $ inStore
        $ \dir -> do
            first <- schemaVersion dir
            opened dir shippedProjections (const (pure ()))
            schemaVersion dir `shouldReturn` first

    it "rebuilds every projection at an open after one's DDL text changed" $
        withRun $ \dir before -> do
            raw dir $ \c ->
                mapM_
                    (execute_ c)
                    [ "DROP TABLE round_problems"
                    , "CREATE TABLE round_problems (run_id TEXT) STRICT"
                    ]
            opened dir shippedProjections (const (pure ()))
            raw
                dir
                (`query_` "SELECT sql FROM sqlite_schema WHERE name = 'round_problems'")
                `shouldReturn` [Only (ddlOf "round_problems")]
            rowsIn dir `shouldReturn` before

    it "rebuilds every projection at an open whose version differs, up or down" $
        withRun $ \dir before ->
            for_ [2, 1] $ \version -> do
                opened dir (at version) (const (pure ()))
                raw dir (`query_` "SELECT version FROM projection_versions")
                    `shouldReturn` [Only (fromIntegral version :: Int)]
                rowsIn dir `shouldReturn` before

    it
        "rebuilds once when two processes open a stale store at once, foreign keys on"
        $ withRun
        $ \dir before -> do
            let stale = raw dir (`execute_` "UPDATE projection_versions SET version = version + 1")
            stale
            fresh <- schemaVersion dir
            opened dir shippedProjections (const (pure ()))
            once <- subtract fresh <$> schemaVersion dir
            stale
            beforeBoth <- schemaVersion dir
            bothAtOnce
                (opened dir shippedProjections (const (pure ())))
                (opened dir shippedProjections (const (pure ())))
            subtract beforeBoth <$> schemaVersion dir `shouldReturn` once
            rowsIn dir `shouldReturn` before
            opened dir shippedProjections $ \store -> do
                query_ store.connection "PRAGMA foreign_keys" `shouldReturn` [Only (1 :: Int)]
                ( query_ store.connection "PRAGMA foreign_key_check" ::
                        IO [(Text, Int, Text, Int)]
                    )
                    `shouldReturn` []

    describe "a row of each constructor" $ do
        it "inserts, and reads back as it was written" $
            withRun $ \dir _ -> opened dir shippedProjections $ \store -> do
                let conn = store.connection
                    written row = do
                        insert conn row
                        projectionRows conn >>= (`shouldSatisfy` Set.isSubsetOf (inserted [row]))
                for_ runStates $ \row ->
                    execute_ conn "DELETE FROM run_states" >> written (runStateInsert row)
                for_ [Nothing, Just epoch] $ \left ->
                    execute_ conn "DELETE FROM step_visits"
                        >> written (stepVisitInsert (StepVisitRow run 1 "plan" epoch left))
                written (loopRoundInsert (LoopRoundRow run "test-loop" 1 1))
                traverse_ (written . roundProblemInsert) (problemRows [minBound .. maxBound])

        for_ refusals $ \(check, bad) ->
            it ("is refused outside its CHECK: " <> Text.unpack check) $
                withRun $ \dir _ -> opened dir shippedProjections $ \store -> do
                    execute_ store.connection "DELETE FROM run_states"
                    insert store.connection (loopRoundInsert (LoopRoundRow run "test-loop" 1 1))
                    refused <- try (insert store.connection bad)
                    refused `shouldSatisfy` refusedBy ("CHECK constraint failed: " <> check)

    modifyMaxSuccess (const 50) $ do
        it "keeps, after each append, the rows a full rebuild makes" . hedgehog $ do
            events <- forAll genAccepted
            let logged = numbered (started :| events)
            cover
                2
                "a round with problems"
                (any ((== "round_problems") . (.table)) (Registry.rows logged))
            (incremental, rebuilt) <- evalIO . withSystemTempDirectory "state-store" $ \dir -> do
                incremental <- opened dir shippedProjections $ \store -> do
                    traverse_ (appended store) logged
                    projectionRows store.connection
                raw dir (`execute_` "DELETE FROM projection_versions")
                (incremental,) <$> rowsIn dir
            incremental === rebuilt

        it "stores the rows the fold makes, each as it was made" . hedgehog $ do
            events <- forAll genAccepted
            let logged = numbered (started :| events)
                rows = Registry.rows logged
            -- The fold takes the log: it has rows.
            assert (not (null rows))
            stored <- evalIO . withSystemTempDirectory "state-store" $ \dir ->
                opened dir shippedProjections $ \store -> do
                    appendedAll store logged
                    projectionRows store.connection
            stored === inserted rows

shippedProjections :: Projections
shippedProjections = projected shipped

-- | The shipped projections, every one at this version.
at :: Natural -> Projections
at version =
    Projections
        { projections = [p {version} | p <- shippedProjections.projections]
        , refold = shippedProjections.refold
        }

-- | A store under this directory, open with these projections for one action.
opened :: FilePath -> Projections -> (Store -> IO a) -> IO a
opened dir ps act =
    withStore Unsynced (dir </> "kernel-v2.db") ps act >>= either (fail . show) pure

-- | A connection to the store's file past the kernel, as an admin opens one.
raw :: FilePath -> (Connection -> IO a) -> IO a
raw dir = SQLite.withConnection (dir </> "kernel-v2.db")

inStore :: (FilePath -> IO a) -> IO a
inStore act = withSystemTempDirectory "state-store" $ \dir ->
    opened dir shippedProjections (const (pure ())) >> act dir

-- | A store holding an engineer run from init to its PR ready, and its projection rows.
withRun :: (FilePath -> Set Row -> IO a) -> IO a
withRun act = withSystemTempDirectory "state-store" $ \dir -> do
    opened dir shippedProjections (`appendedAll` engineerRun)
    rows <- rowsIn dir
    rows `shouldSatisfy` (not . null)
    act dir rows

rowsIn :: FilePath -> IO (Set Row)
rowsIn dir = opened dir shippedProjections (projectionRows . (.connection))

schemaVersion :: FilePath -> IO Int
schemaVersion dir =
    raw dir (`query_` "PRAGMA schema_version") >>= \case
        [Only v] -> pure v
        _ -> fail "no schema version"

engineerRun :: NonEmpty Envelope
engineerRun = numbered (started :| fuelSet Balanced : happyPath)

-- | The lines of these events, from seq 1 as the store numbers them.
numbered :: NonEmpty Event -> NonEmpty Envelope
numbered = NonEmpty.zipWith line (1 :| [2 ..])

-- | One line appended, as the kernel's write appends it.
appended :: Store -> Envelope -> IO ()
appended store e =
    Store.locked
        store
        (runIdText e.run)
        (const (Just (Batch (writeOf (e :| [])) []), ()))

-- | Every line appended in one write.
appendedAll :: Store -> NonEmpty Envelope -> IO ()
appendedAll store logged@(first :| _) =
    Store.locked
        store
        (runIdText first.run)
        (const (Just (Batch (writeOf logged) []), ()))

writeOf :: NonEmpty Envelope -> Write
writeOf logged@(first :| _) = case runRow first of
    Just started' -> Start started' (fmap eventRow logged)
    Nothing -> Append (fmap eventRow logged)

-- | The statement of a projection table, as the kernel makes it.
ddlOf :: Text -> Text
ddlOf name = case [t.ddl | p <- Registry.projections, t <- toList p.tables, t.name == name] of
    [ddl] -> ddl
    _ -> error ("no projection table " <> Text.unpack name)

-- | A run state of every status, stop reason and Fuel.
runStates :: [RunStateRow]
runStates =
    [ runState status stop fuel
    | status <- [minBound .. maxBound]
    , stop <- stopsOf status
    , fuel <- [minBound .. maxBound]
    ]
  where
    stopsOf = \case
        Active -> [Nothing]
        Stopped -> [Just (Stop reason "why") | reason <- [minBound .. maxBound]]
        Finished -> [Nothing]

runState :: RunStatus -> Maybe Stop -> Fuel -> RunStateRow
runState status stop fuel =
    RunStateRow
        { runId = run
        , status
        , step = "plan"
        , stop
        , fuel
        , goal = Just "a goal"
        , worktree = "/w"
        , repo = Just "o/r"
        , prUrl = Nothing
        , baseBranch = Nothing
        , headBranch = Nothing
        , ticketUrl = Nothing
        }

problemRows :: [ProblemKind] -> [RoundProblemRow]
problemRows kinds = [RoundProblemRow run "test-loop" 1 kind "x" | kind <- kinds]

-- | Each named CHECK of the runs projection, and a row it refuses.
refusals :: [(Text, Insert)]
refusals =
    [ ("run_states_status_enum", with "status" "paused" (runStateInsert active))
    ,
        ( "run_states_stop_reason_enum"
        , with "stop_reason" "tired" (runStateInsert stopped)
        )
    , ("run_states_fuel_enum", with "fuel" "huge" (runStateInsert active))
    ,
        ( "run_states_stop_reason_iff_stopped"
        , with "stop_reason" "blocked" (runStateInsert active)
        )
    ,
        ( "run_states_stop_detail_iff_stopped"
        , with "stop_detail" "why" (runStateInsert active)
        )
    ,
        ( "round_problems_kind_enum"
        , with
            "kind"
            "odd"
            (roundProblemInsert (RoundProblemRow run "test-loop" 1 minBound "x"))
        )
    ]
  where
    active = runState Active Nothing Balanced
    stopped = runState Stopped (Just (Stop minBound "why")) Balanced
    with column value row =
        row
            { values =
                fmap (\(c, v) -> (c, if c == column then SqlText value else v)) row.values
            }

refusedBy :: Text -> Either SQLError () -> Bool
refusedBy message = \case
    Left e -> message `Text.isInfixOf` e.sqlErrorDetails
    Right () -> False

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 11 13) 0
