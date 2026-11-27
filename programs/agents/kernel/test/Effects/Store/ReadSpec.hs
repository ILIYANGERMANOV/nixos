{- | The read side on a real store (#552 s9): @state sql@'s guards and TSV,
and each fixed report, through the log's own interpreter on SQLite in a
temp dir. The in-memory double has no SQL.
-}
module Effects.Store.ReadSpec (spec) where

import Data.Field qualified as Field
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Database.SQLite.Simple qualified as SQLite
import Effectful (Eff, (:>))
import Effects.Log (Log, locked)
import Effects.Log qualified as Log
import Effects.Store.Fixtures (asking, atStore, contextRun)
import Hedgehog (evalIO, forAll, (===))
import State.Category.Fuel (Fuel (Balanced))
import State.Cli.Query (Report (..), SqlRefusal (..), Window (..), parseSince)
import State.Run.Event (Envelope (..), Event (GapMoved, Gapped), RunId)
import State.Run.EventGen (
    bareGap,
    fuelSet,
    lineOf,
    oneLine,
    run,
    runId,
    started,
 )
import State.Run.Fold (RunState (..))
import State.Run.Fold qualified as Fold
import State.Run.Gap (Closure (..), GapMove (..), Tracked (..), isOpen)
import State.Run.RunGen (g, genAccepted)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)

spec :: Spec
spec = describe "the store's read side" $ do
    describe "state sql" $ do
        it "prints the rows of a SELECT as TSV, its header first" $
            withFixture
                ( Log.sql
                    "SELECT step_visit_id, step FROM v_steps WHERE run_id = 'r7f2' AND left_at IS NULL"
                )
                `shouldReturn` Right "step_visit_id\tstep\n16\tplan\n"

        it "spells NULL, the empty text, a number and a blob as COPY text does" $
            withFixture
                (Log.sql "SELECT NULL AS n, '' AS e, '\\N' AS t, 1.5 AS r, 2 AS i, x'0aff' AS b")
                `shouldReturn` Right "n\te\tt\tr\ti\tb\n\\N\t\t\\\\N\t1.5\t2\t\\\\x0aff\n"

        it "refuses a write, an ATTACH, a PRAGMA and a recursive CTE as not read-only" $
            withFixture (traverse Log.sql writes)
                `shouldReturn` map (const (Left SqlNotReadOnly)) writes

        it "leaves the log as it was after an ATTACH read-write and a DELETE through it" $
            withSystemTempDirectory "state-read" $ \dir -> do
                seed dir
                let db = Text.pack (dir </> "state" </> "kernel-v2.db")
                    probe = "ATTACH 'file:" <> db <> "?mode=rw' AS w; DELETE FROM w.events"
                before <- atStore dir (Log.rows run)
                atStore dir (traverse Log.sql [probe, "DELETE FROM main.events"])
                    `shouldReturn` [Left SqlNotReadOnly, Left SqlNotReadOnly]
                atStore dir (Log.rows run) `shouldReturn` before
                length before `shouldBe` length contextRun

        it "runs exactly one statement: none, or a second, is refused" $
            withFixture
                (traverse Log.sql ["", "  -- a comment", "SELECT 1; SELECT 2", "SELECT 1; nope"])
                `shouldReturn` replicate 4 (Left SqlNotOneStatement)

        it "takes one statement with a semicolon and a comment after it" $
            withFixture (Log.sql "SELECT 1 AS one; -- done") `shouldReturn` Right "one\n1\n"

        it "tells SQLite's error for a statement it cannot run" $
            withFixture (Log.sql "SELECT nope FROM runs")
                `shouldReturn` Left (SqlError "no such column: nope")

        it "prints the column comments of the schema" $
            withFixture (Log.sql "SELECT sql FROM sqlite_schema WHERE name = 'runs'")
                >>= (`shouldSatisfy` either (const False) ("-- One row per run." `Text.isInfixOf`))

    describe "state report" $ do
        it "runs: one row per run, its counts over the log and the projections" $
            withFixture (cellsOf <$> Log.report RunsReport everything)
                >>= ( `shouldBe`
                        [
                            [ "run_id"
                            , "parent_run_id"
                            , "flow"
                            , "status"
                            , "created_at"
                            , "last_event_at"
                            , "session_count"
                            , "event_count"
                            , "span_count"
                            , "input_tokens"
                            , "output_tokens"
                            , "open_gap_count"
                            , "signal_count"
                            ]
                        ,
                            [ "g1ap"
                            , "\\N"
                            , "engineer"
                            , "active"
                            , at 1
                            , at 5
                            , "0"
                            , "5"
                            , "0"
                            , "\\N"
                            , "\\N"
                            , "1"
                            , "0"
                            ]
                        ,
                            [ "r7f2"
                            , "\\N"
                            , "engineer"
                            , "stopped"
                            , at 1
                            , at 17
                            , "1"
                            , "17"
                            , "2"
                            , "\\N"
                            , "\\N"
                            , "0"
                            , "2"
                            ]
                        ]
                    )

        it "steps and signals: the columns of v_steps and v_signals, one run's" $
            withFixture
                ( (,) . headOf
                    <$> Log.report StepsReport (Window Nothing (Just gapRunId))
                    <*> (cellsOf <$> Log.report SignalsReport (Window Nothing (Just run)))
                )
                `shouldReturn` (
                                   [ "run_id"
                                   , "step_visit_id"
                                   , "step"
                                   , "entered_at"
                                   , "left_at"
                                   , "duration_seconds"
                                   , "agent_seconds"
                                   ]
                               ,
                                   [ ["run_id", "seq", "time", "session_id", "signal", "code", "detail"]
                                   , ["r7f2", "16", at 16, "\\N", "overridden", "plan", "the research is in"]
                                   , ["r7f2", "17", at 17, "\\N", "stop", "blocked", "out of options"]
                                   ]
                               )

        it "gaps: each gap as <run>:<seq>, where its fix stands" $
            withFixture (cellsOf <$> Log.report GapsReport everything)
                `shouldReturn` [
                                   [ "gap"
                                   , "kind"
                                   , "severity"
                                   , "area"
                                   , "status"
                                   , "fix_pr_url"
                                   , "wont_fix_reason"
                                   , "reporter_role"
                                   , "text"
                                   ]
                               ,
                                   [ "g1ap:3"
                                   , "other"
                                   , "slowdown"
                                   , "plan"
                                   , "open"
                                   , "\\N"
                                   , "\\N"
                                   , "engineer"
                                   , "slow"
                                   ]
                               ,
                                   [ "g1ap:4"
                                   , "other"
                                   , "slowdown"
                                   , "plan"
                                   , "wont_fix"
                                   , "\\N"
                                   , "not now"
                                   , "engineer"
                                   , "done"
                                   ]
                               ]

        it "waits: per run and step, its visits, time, agent time and rest" $
            withFixture (cellsOf <$> Log.report WaitsReport (Window Nothing (Just run)))
                `shouldReturn` [
                                   [ "run_id"
                                   , "step"
                                   , "visit_count"
                                   , "duration_seconds"
                                   , "agent_seconds"
                                   , "rest_seconds"
                                   ]
                               , ["r7f2", "fuel", "1", "1.0", "0", "1.0"]
                               , -- Two spans of 4s overlap in 5s: the agent time sums them, the rest does not.
                                 ["r7f2", "gather", "1", "14.0", "8.0", "9.0"]
                               , ["r7f2", "plan", "1", "\\N", "\\N", "\\N"]
                               ]

        it "keeps rows at or after --since, by each row's own time" $
            withFixture
                ( traverse
                    ( \t ->
                        length . cellsOf <$> Log.report SignalsReport (Window (parseSince t) Nothing)
                    )
                    [timeOf 17, timeOf 18]
                )
                `shouldReturn` [2, 1]

    modifyMaxSuccess (const 20) $
        it "report_totals_equal_sums_over_the_projections" . hedgehog $ do
            logged <- forAll (genAccepted >>= asking)
            let final = snd (NonEmpty.last (either (error . show) id (Fold.trace g logged)))
            (runs, waits, signals, counts) <- evalIO . withSystemTempDirectory "state-read" $ \dir -> do
                atStore dir (locked run (const (toList logged, ())))
                reports <-
                    atStore dir $
                        (,,)
                            <$> Log.report RunsReport everything
                            <*> Log.report WaitsReport everything
                            <*> Log.report SignalsReport everything
                counted <-
                    SQLite.withConnection (dir </> "state" </> "kernel-v2.db") $ \c ->
                        traverse
                            (fmap (\rows -> sum [n | SQLite.Only n <- rows]) . SQLite.query_ c)
                            [ "SELECT count(*) FROM events"
                            , "SELECT count(*) FROM spans"
                            , "SELECT count(*) FROM step_visits"
                            , "SELECT count(*) FROM v_signals"
                            ]
                let (r, w, s) = reports in pure (r, w, s, counted)
            let total name table = sum (map (read . Text.unpack) (column name table)) :: Int
            [ total "event_count" runs
                , total "span_count" runs
                , total "visit_count" waits
                , total "signal_count" runs
                ]
                === counts
            length (drop 1 (cellsOf signals)) === counts !! 3
            total "open_gap_count" runs
                === length [() | (_, t) <- final.gaps, isOpen t.status]
  where
    everything = Window Nothing Nothing
    writes =
        [ "INSERT INTO runs (id, flow, notes_dir, created_at) VALUES ('x', 'f', 'n', '2026-01-01T00:00:00.000Z')"
        , "UPDATE runs SET flow = 'f'"
        , "DELETE FROM events"
        , "ATTACH ':memory:' AS x"
        , "DETACH main"
        , "PRAGMA query_only = 0"
        , "SELECT * FROM pragma_table_info('runs')"
        , "VACUUM INTO '/tmp/state-read-vacuum.db'"
        , "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3) SELECT x FROM c"
        , "CREATE TABLE t (a)"
        , "DROP VIEW v_steps"
        , "BEGIN"
        ]
    at = timeOf
    timeOf n = Field.encode Field.time (lineOf run n started).ts

-- | The store a test reads: the context run, and a run of gaps, one closed.
withFixture :: (forall es. (Log :> es) => Eff es a) -> IO a
withFixture program = withSystemTempDirectory "state-read" $ \dir -> seed dir >> atStore dir program

seed :: FilePath -> IO ()
seed dir =
    atStore
        dir
        ( mapM_
            (\logged -> locked (NonEmpty.head logged).run (const (toList logged, ())))
            [contextRun, gapRun]
        )

gapRunId :: RunId
gapRunId = runId "g1ap"

gapRun :: NonEmpty Envelope
gapRun =
    NonEmpty.zipWith
        (lineOf gapRunId)
        (1 :| [2 ..])
        ( started
            :| [ fuelSet Balanced
               , Gapped (bareGap "slow")
               , Gapped (bareGap "done")
               , GapMoved 4 (Close (WontFix (oneLine "not now")))
               ]
        )

-- | A report's lines, each split into its cells: no cell holds a raw tab.
cellsOf :: Text -> [[Text]]
cellsOf = map (Text.splitOn "\t") . Text.lines

headOf :: Text -> [Text]
headOf = concat . take 1 . cellsOf

-- | A column's cells, under its header.
column :: Text -> Text -> [Text]
column name table = case cellsOf table of
    header : rows -> [cell | row <- rows, (h, cell) <- zip header row, h == name]
    [] -> []
