{- | The projections in a real store: made at open as SQLite keeps their
DDL, rebuilt whole and once when stale, replaced in each append to the rows
a full rebuild makes, which are the rows the fold makes.
-}
module Effects.Store.ProjectionSpec (spec) where

import Concurrently (bothAtOnce)
import Control.Exception (try)
import Data.Either (isRight)
import Data.Field qualified as Field
import Data.Foldable (for_, toList, traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Projection (
    Insert (..),
    Projection (..),
    Projections (..),
    Table (..),
    Value (..),
 )
import Data.Projection.Context (
    ArtifactRow (..),
    HandoverRow (..),
    NoteRow (..),
    StopgapRow (..),
    artifactInsert,
    handoverInserts,
    noteInsert,
    stopgapInsert,
 )
import Data.Projection.Gaps (GapRow (..), evidenceInserts, gapInsert)
import Data.Projection.Questions (
    AnswerRow (..),
    QuestionRow (..),
    RulingBasis (..),
    RulingRow (..),
    Standing (..),
    UserNeedBlockRow (..),
    UserNeedRow (..),
    answerInsert,
    questionInsert,
    rulingInsert,
    userNeedBlockInsert,
    userNeedInsert,
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
import Data.Projection.Spans (SpanEnd (..), SpanRow (..), spanInsert)
import Data.Projection.Tasks (
    BreakdownRow (..),
    ChildRunRow (..),
    EpicRow (..),
    HoldStatus (..),
    Progress (..),
    TaskDependencyRow (..),
    TaskHoldRow (..),
    TaskRow (..),
    breakdownInsert,
    childRunInsert,
    epicInsert,
    taskDependencyInsert,
    taskHoldInsert,
    taskInsert,
 )
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple (
    Only (..),
    SQLError (..),
    execute_,
    query_,
 )
import Database.SQLite.Simple qualified as SQLite
import Effects.Store.Connection (Store (..))
import Effects.Store.Fixtures (
    appended,
    appendedAll,
    asking,
    contextRun,
    fileRef,
    opened,
    raw,
    shippedProjections,
    stopgapPool,
 )
import Effects.Store.Projected (Row, inserted, projectionRows)
import Effects.Store.Projection (insert)
import Hedgehog (assert, cover, evalIO, forAll, (===))
import Numeric.Natural (Natural)
import State.Artifact (
    Artifact (File),
    FileArtifact (..),
 )
import State.Artifact qualified as Artifact
import State.Category.Fuel (Fuel (Balanced))
import State.Category.Step (StateName (..))
import State.Golden (golden)
import State.Role (AgentRole (..), FlowName (TenXFlow), graphOf)
import State.Run.Ask (
    Above (..),
    Basis (..),
    Kind (..),
    Proposal (..),
    QId (..),
    Question (..),
    Reply (..),
 )
import State.Run.Codec (taskStateKind)
import State.Run.Epic (
    MergedEpic (..),
    OpenEpic (..),
    ReadyEpic (..),
    stageName,
 )
import State.Run.Epic qualified as Epic
import State.Run.Event (
    Asker (..),
    Asking (..),
    Base (..),
    Branch (..),
    Child (..),
    ChildTask (..),
    Envelope (..),
    EpicMove (..),
    Event (
        ActedOn,
        Answered,
        Asked,
        EpicMoved,
        Forwarded,
        HandedBack,
        Held,
        Overridden,
        QuestionParked,
        RuledOn,
        Spawned,
        Started,
        TaskMoved,
        UserNeeded
    ),
    Handover (..),
    HandoverReason (Context),
    Harness (..),
    Need (..),
    Repo (..),
    RunId,
    Said (Ended),
    Source (..),
    SpanEnding (..),
    SpanStart (..),
    Stop (..),
    StopReason (..),
    Task (..),
    TaskId (..),
    TaskRef (..),
    TaskState (..),
    TokenWord (ReadyWord),
    Url (..),
    Usage (..),
    runIdText,
    stepTook,
    unreported,
 )
import State.Run.Event qualified as Event
import State.Run.Event qualified as Started (Start (..))
import State.Run.EventGen (
    bareGap,
    epicNamed,
    fuelSet,
    ijson,
    line,
    lineOf,
    oneLine,
    run,
    runId,
    start,
    started,
    stopgapKey,
    tasksOf,
    titled,
    uri,
 )
import State.Run.Fold (
    RunState (..),
    Waits (..),
 )
import State.Run.Fold qualified as Fold
import State.Run.Gap (Evidence (..), Gap (..), Tracked (..))
import State.Run.Gap qualified as Gap
import State.Run.Id (Digest (..), EventId (..), EventRef (..), SpanId (..))
import State.Run.RunGen (g, genAccepted, happyPath, plainTask, sha)
import State.Run.Stopgap (Stopgap (..), StopgapAt (..))
import State.Step.Fan (Outcome (BreakdownDone), engineers)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    it,
    runIO,
    shouldBe,
    shouldReturn,
    shouldSatisfy,
 )
import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)

spec :: Spec
spec = describe "Effects.Store.Projection" $ do
    schema <-
        runIO . withSystemTempDirectory "state-store" $ \dir -> do
            reopened dir
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
            reopened dir
            schemaVersion dir `shouldReturn` first

    it "rebuilds every projection at an open after one's DDL text changed" $
        withRun $ \dir before -> do
            raw dir $ \c ->
                mapM_
                    (execute_ c)
                    [ "DROP TABLE round_problems"
                    , "CREATE TABLE round_problems (run_id TEXT) STRICT"
                    ]
            reopened dir
            raw
                dir
                (`query_` "SELECT sql FROM sqlite_schema WHERE name = 'round_problems'")
                `shouldReturn` [Only (ddlOf "round_problems")]
            rowsIn dir `shouldReturn` before

    it
        "rebuilds every projection at an open after a view's text or an index changed"
        $ withRun
        $ \dir before -> do
            let made =
                    raw dir $ \c ->
                        query_
                            c
                            "SELECT name, sql FROM sqlite_schema WHERE name IN ('v_steps', 'notes_run_id_topic_idx') ORDER BY name"
            shipped' <- made :: IO [(Text, Text)]
            raw dir $ \c ->
                mapM_
                    (execute_ c)
                    [ "DROP VIEW v_steps"
                    , "CREATE VIEW v_steps AS SELECT 1 AS one"
                    , "DROP INDEX notes_run_id_topic_idx"
                    ]
            reopened dir
            made `shouldReturn` shipped'
            map fst shipped' `shouldBe` ["notes_run_id_topic_idx", "v_steps"]
            rowsIn dir `shouldReturn` before

    it "rebuilds every projection at an open whose version differs, up or down" $
        withRun $ \dir before ->
            for_ [2, 1] $ \version -> do
                opened dir (at version) (const (pure ()))
                raw dir (`query_` "SELECT DISTINCT version FROM projection_versions")
                    `shouldReturn` [Only (fromIntegral version :: Int)]
                rowsIn dir `shouldReturn` before

    it
        "rebuilds once when two processes open a stale store at once, foreign keys on"
        $ withRun
        $ \dir before -> do
            let stale = raw dir (`execute_` "UPDATE projection_versions SET version = version + 1")
            stale
            fresh <- schemaVersion dir
            reopened dir
            once <- subtract fresh <$> schemaVersion dir
            stale
            beforeBoth <- schemaVersion dir
            bothAtOnce
                (reopened dir)
                (reopened dir)
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
                written (breakdownInsert (BreakdownRow run 1 "engineers"))
                traverse_ (written . epicInsert) epicRows
                traverse_ (written . taskInsert) taskRows
                written
                    (taskDependencyInsert (TaskDependencyRow run 1 (TaskId "p1") (TaskId "t0")))
                for_ childRunRows $ \row ->
                    execute_ conn "DELETE FROM child_runs" >> written (childRunInsert row)
                for_ (zip [1 ..] [minBound .. maxBound]) $ \(id', status) ->
                    written
                        (taskHoldInsert (TaskHoldRow run id' (TaskRef (TaskId "t0") 1) (Url "u") status))
                for_ questionRows $ \row ->
                    execute_ conn "DELETE FROM questions" >> written (questionInsert row)
                for_ rulingRows $ \row ->
                    execute_ conn "DELETE FROM rulings" >> written (rulingInsert row)
                for_ answerRows $ \row ->
                    execute_ conn "DELETE FROM answers" >> written (answerInsert row)
                traverse_ (written . userNeedInsert) userNeedRows
                written (userNeedBlockInsert (UserNeedBlockRow run 1 (TaskRef (TaskId "t0") 1)))
                for_ gapRows $ \row -> do
                    execute_ conn "DELETE FROM gap_evidence"
                    execute_ conn "DELETE FROM gaps"
                    traverse_ written (gapInsert row : evidenceInserts row)
                written (noteInsert (NoteRow run 1 "traps" "cold cache"))
                for_ spanRows $ \row ->
                    execute_ conn "DELETE FROM spans WHERE id = 3" >> written (spanInsert row)
                for_ artifactRows $ \row ->
                    execute_ conn "DELETE FROM artifacts WHERE id = 2"
                        >> written (artifactInsert row)
                for_ [minBound .. maxBound] $ \reason -> do
                    execute_ conn "DELETE FROM handover_next_steps"
                    execute_ conn "DELETE FROM handovers"
                    traverse_
                        written
                        (handoverInserts (HandoverRow run 1 (Handover reason "s" ("a" :| ["b"]))))
                traverse_ (written . stopgapInsert) stopgapRows

        it
            "spells each task state's status as the log's kind, and each epic's as its stage"
            $ ( [ statusOf (taskInsert (taskRow "t0" OnDefault (Moved moved) False))
                | moved <- taskStates
                ]
              , [statusOf (epicInsert row) | row <- epicRows]
              )
                `shouldBe` ( map (Just . SqlText . taskStateKind) taskStates
                           , [Just (SqlText (stageName row.epic)) | row <- epicRows]
                           )

        for_ refusals $ \(check, bad) ->
            it ("is refused outside its CHECK: " <> Text.unpack check) $
                withRun $ \dir _ -> opened dir shippedProjections $ \store -> do
                    execute_ store.connection "DELETE FROM run_states"
                    insert store.connection (loopRoundInsert (LoopRoundRow run "test-loop" 1 1))
                    refused <- try (insert store.connection bad)
                    refused `shouldSatisfy` refusedBy ("CHECK constraint failed: " <> check)

    describe "a 10x run's tasks and questions" $ do
        let rowsOf table =
                [ columns
                | (t, columns) <- Set.toList (inserted (Registry.rows tenXRun))
                , t == table
                ]
            row table key =
                filter
                    (\columns -> all (\(c, v) -> Map.lookup c columns == Just v) key)
                    (rowsOf table)
            column name = map (Map.lookup name)

        it "folds, so it has rows" $
            Fold.trace (graphOf TenXFlow) tenXRun `shouldSatisfy` isRight

        it "spells a delivered task delivered, its PR kept (D4)" $
            column "status" (row "tasks" [("id", SqlText "t3")])
                `shouldBe` [Just (SqlText "delivered")]

        it "keeps the last pending status of a question a stop ended (D5)" $
            [ (column "status" r, column "parked_reason" r)
            | id' <- [22, 25]
            , let r = row "questions" [("id", SqlInteger id')]
            ]
                `shouldBe` [ ([Just (SqlText "parked")], [Just (SqlText "after the release")])
                           , ([Just (SqlText "in_triage")], [Just SqlNull])
                           ]

        it
            "rests a hashed basis on its hook line, and one no line holds on no line (D6)"
            $ [ map
                    (\c -> Map.lookup c =<< listToMaybe r)
                    ["basis_kind", "basis_event_run_id", "basis_event_seq"]
              | id' <- [11, 13]
              , let r = row "rulings" [("question_id", SqlInteger id')]
              ]
                `shouldBe` [ [Just (SqlText "event"), Just (SqlText (runIdText run)), Just (SqlInteger 6)]
                           , [Just (SqlText "event"), Just SqlNull, Just SqlNull]
                           ]

        it "gives a child that stopped to re-plan no token (D8)" $
            column
                "handback_token"
                (row "child_runs" [("child_run_id", SqlText (runIdText c1))])
                `shouldBe` [Just SqlNull]

        it
            "keeps a hold acted on acted, and one held when a new breakdown came open (D10)"
            $ [column "status" (row "task_holds" [("id", SqlInteger id')]) | id' <- [7, 8]]
                `shouldBe` [[Just (SqlText "acted")], [Just (SqlText "open")]]

        it "stores the rows the fold makes, its child's beside it" $
            withSystemTempDirectory "state-store" $ \dir -> do
                stored <- opened dir shippedProjections $ \store -> do
                    appendedAll store childRun
                    appendedAll store tenXRun
                    projectionRows store.connection
                stored `shouldBe` inserted (Registry.rows childRun <> Registry.rows tenXRun)

        it "keeps, after each append, the rows a full rebuild makes" $
            withSystemTempDirectory "state-store" $ \dir -> do
                incremental <- opened dir shippedProjections $ \store -> do
                    appendedAll store childRun
                    traverse_ (appended store) tenXRun
                    projectionRows store.connection
                raw dir (`execute_` "DELETE FROM projection_versions")
                rowsIn dir `shouldReturn` incremental

        it "keeps each breakdown's tasks, the replaced one's too" $
            Set.fromList
                [map (`Map.lookup` r) ["breakdown_id", "id", "status"] | r <- rowsOf "tasks"]
                `shouldBe` Set.fromList
                    [ [Just (SqlInteger 5), Just (SqlText "t1"), Just (SqlText "planned")]
                    , [Just (SqlInteger 5), Just (SqlText "t2"), Just (SqlText "planned")]
                    , [Just (SqlInteger 19), Just (SqlText "t3"), Just (SqlText "delivered")]
                    ]

    describe "a run's context, gaps and spans" $ do
        let rowsOf table =
                [ columns
                | (t, columns) <- Set.toList (inserted (Registry.rows contextRun))
                , t == table
                ]
            columnsOf table names' = [map (`Map.lookup` r) names' | r <- rowsOf table]

        it "keeps the artifact an artifact was made from, and the span that made it" $
            columnsOf "artifacts" ["id", "source_artifact_id", "span_id"]
                `shouldBe` [ [Just (SqlInteger 5), Just SqlNull, Just (SqlInteger 3)]
                           , [Just (SqlInteger 6), Just (SqlInteger 5), Just (SqlInteger 4)]
                           ]

        it
            "times a span from its start and end lines, its harness's agent and provider unknown (D7)"
            $ columnsOf
                "spans"
                [ "id"
                , "parent_span_id"
                , "started_at"
                , "ended_at"
                , "status_code"
                , "harness_agent_id"
                , "provider_name"
                ]
                `shouldBe` [
                               [ Just (SqlInteger 3)
                               , Just SqlNull
                               , at' 3
                               , at' 7
                               , Just (SqlText "ok")
                               , Just SqlNull
                               , Just SqlNull
                               ]
                           ,
                               [ Just (SqlInteger 4)
                               , Just (SqlInteger 3)
                               , at' 4
                               , at' 8
                               , Just (SqlText "error")
                               , Just SqlNull
                               , Just SqlNull
                               ]
                           ]

        it
            "keeps the stopgaps in force, each by the line that set it, its value and reason (D2)"
            $ columnsOf "stopgaps" ["id", "breakdown_id", "task_id", "key", "value", "reason"]
                `shouldBe` [
                               [ Just (SqlInteger 13)
                               , Just SqlNull
                               , Just SqlNull
                               , Just (SqlText "a.b")
                               , Just (SqlText "\"y\"")
                               , Just (SqlText "newer")
                               ]
                           ]

        it "stores a stopgap set, and drops its row once unset" $
            withSystemTempDirectory "state-store" $ \dir -> do
                let (set, unset) = NonEmpty.splitAt 12 contextRun
                    stopgaps store =
                        query_ store.connection "SELECT id, key, value FROM stopgaps ORDER BY id"
                opened dir shippedProjections $ \store -> do
                    traverse_ (appended store) set
                    (stopgaps store :: IO [(Int, Text, Text)])
                        `shouldReturn` [(11, "a.b", "\"x\""), (12, "deploy.window", "1")]
                    traverse_ (appended store) unset
                    (stopgaps store :: IO [(Int, Text, Text)]) `shouldReturn` [(13, "a.b", "\"y\"")]

        it "stores the rows the fold makes, and a rebuild makes them again" $
            withSystemTempDirectory "state-store" $ \dir -> do
                incremental <- opened dir shippedProjections $ \store -> do
                    traverse_ (appended store) contextRun
                    projectionRows store.connection
                incremental `shouldBe` inserted (Registry.rows contextRun)
                raw dir (`execute_` "DELETE FROM projection_versions")
                rowsIn dir `shouldReturn` incremental

        describe "the views" $ do
            let viewed :: (SQLite.FromRow r) => SQLite.Query -> IO [r]
                viewed sql = withSystemTempDirectory "state-store" $ \dir ->
                    opened dir shippedProjections $ \store -> do
                        appendedAll store contextRun
                        query_ store.connection sql

            it "v_steps: a visit's length, and its spans' time inside it summed" $
                viewed
                    "SELECT step_visit_id, duration_seconds, agent_seconds FROM v_steps WHERE agent_seconds > 0"
                    `shouldReturn` [(2 :: Int, 14 :: Double, 8 :: Double)]

            it "v_signals: the override and the stop, each with its code and words" $
                viewed "SELECT seq, signal, code, detail FROM v_signals ORDER BY seq"
                    `shouldReturn` [
                                       ( 16 :: Int
                                       , "overridden" :: Text
                                       , Just ("plan" :: Text)
                                       , Just ("the research is in" :: Text)
                                       )
                                   , (17, "stop", Just "blocked", Just "out of options")
                                   ]

            it "v_sessions: each session's lines, hand-overs and harness" $
                viewed "SELECT session_id, event_count, handover_count, harness FROM v_sessions"
                    `shouldReturn` [("s1" :: Text, 3 :: Int, 1 :: Int, Just ("claude-code" :: Text))]

    modifyMaxSuccess (const 50) $ do
        it "keeps, after each append, the rows a full rebuild makes" . hedgehog $ do
            logged <- forAll (genAccepted >>= asking)
            let tables = map (.table) (Registry.rows logged)
            cover 2 "a round with problems" ("round_problems" `elem` tables)
            cover 5 "a ruling" ("rulings" `elem` tables)
            cover 5 "an answer" ("answers" `elem` tables)
            cover 5 "a gap with evidence" ("gap_evidence" `elem` tables)
            cover 5 "a note" ("notes" `elem` tables)
            cover 5 "a hand-over" ("handover_next_steps" `elem` tables)
            cover 5 "a stopgap in force" ("stopgaps" `elem` tables)
            cover
                5
                "an artifact from an earlier one"
                (anyColumn "source_artifact_id" logged)
            cover 5 "an artifact made by a span" (anyColumn "span_id" logged)
            cover 5 "a span ended" (anyColumn "ended_at" logged)
            cover 2 "a span under another" (anyColumn "parent_span_id" logged)
            (incremental, rebuilt) <- evalIO . withSystemTempDirectory "state-store" $ \dir -> do
                incremental <- opened dir shippedProjections $ \store -> do
                    traverse_ (appended store) logged
                    projectionRows store.connection
                raw dir (`execute_` "DELETE FROM projection_versions")
                (incremental,) <$> rowsIn dir
            incremental === rebuilt

        it "stores the rows the fold makes, each as it was made" . hedgehog $ do
            logged <- forAll (genAccepted >>= asking)
            let rows = Registry.rows logged
            cover 5 "a question a stop ended" (stopEnded logged)
            -- The fold takes the log: it has rows.
            assert (not (null rows))
            stored <- evalIO . withSystemTempDirectory "state-store" $ \dir ->
                opened dir shippedProjections $ \store -> do
                    appendedAll store logged
                    projectionRows store.connection
            stored === inserted rows

-- | Whether a row the log makes sets this column.
anyColumn :: Text -> NonEmpty Envelope -> Bool
anyColumn column logged =
    or
        [ value /= SqlNull
        | row <- Registry.rows logged
        , (c, value) <- toList row.values
        , c == column
        ]

-- | A question of the log's is pending when its stop ends it.
stopEnded :: NonEmpty Envelope -> Bool
stopEnded logged = case (NonEmpty.last logged).event of
    Event.Stopped _ -> any (\(_, state) -> not (null state.pending)) (lastTwo logged)
    _ -> False
  where
    lastTwo = either (const []) (take 1 . drop 1 . reverse . toList) . Fold.trace g

-- | The shipped projections, every one at this version.
at :: Natural -> Projections
at version =
    Projections
        { projections = [p {version} | p <- shippedProjections.projections]
        , views = shippedProjections.views
        , refold = shippedProjections.refold
        }

inStore :: (FilePath -> IO a) -> IO a
inStore act = withSystemTempDirectory "state-store" $ \dir ->
    reopened dir >> act dir

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

-- | The store under this directory opened once more, as the next command opens it.
reopened :: FilePath -> IO ()
reopened dir = opened dir shippedProjections (const (pure ()))

-- | The statement of a projection table, as the kernel makes it.
ddlOf :: Text -> Text
ddlOf name = case [t.ddl | p <- Registry.projections, t <- toList p.tables, t.name == name] of
    [ddl] -> ddl
    _ -> error ("no projection table " <> Text.unpack name)

-- | A run state of every status, stop reason and Fuel.
runStates :: [RunStateRow]
runStates =
    [ runState status fuel
    | status <-
        Active
            : Finished
            : [Stopped (Stop reason "why") | reason <- [minBound .. maxBound]]
    , fuel <- [minBound .. maxBound]
    ]

runState :: RunStatus -> Fuel -> RunStateRow
runState status fuel =
    RunStateRow
        { runId = run
        , status
        , step = "plan"
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
    , ("epics_status_enum", with "status" "closed" (epicInsert openEpic))
    , ("epics_pr_url_iff_ready_or_merged", with "pr_url" "u" (epicInsert openEpic))
    , ("tasks_base_kind_enum", with "base_kind" "on_air" (taskInsert planned))
    , ("tasks_status_enum", with "status" "lost" (taskInsert planned))
    ,
        ( "tasks_at_work_boolean"
        , withValue "at_work" (SqlInteger 2) (taskInsert running)
        )
    ,
        ( "tasks_base_epic_name_iff_on_epic"
        , with "base_epic_name" "e" (taskInsert planned)
        )
    ,
        ( "tasks_base_task_id_iff_on_task"
        , with "base_task_id" "t9" (taskInsert planned)
        )
    ,
        ( "tasks_base_task_id_not_self"
        , taskInsert (taskRow "t0" (OnTask (TaskId "t0")) Planned False)
        )
    ,
        ( "tasks_parked_reason_iff_parked"
        , with "parked_reason" "why" (taskInsert planned)
        )
    ,
        ( "tasks_pr_url_required_by_status"
        , withValue
            "pr_url"
            SqlNull
            (taskInsert (taskRow "t0" OnDefault (Moved (Delivered (Url "u"))) False))
        )
    ,
        ( "tasks_at_work_never_planned_or_parked"
        , withValue "at_work" (SqlInteger 1) (taskInsert planned)
        )
    ,
        ( "task_dependencies_after_task_id_not_self"
        , taskDependencyInsert (TaskDependencyRow run 1 (TaskId "t0") (TaskId "t0"))
        )
    ,
        ( "child_runs_handback_token_enum"
        , with "handback_token" "maybe" (childRunInsert untasked)
        )
    ,
        ( "child_runs_task_id_iff_breakdown_id"
        , with "task_id" "t0" (childRunInsert untasked)
        )
    , ("task_holds_status_enum", with "status" "dropped" (taskHoldInsert hold))
    , ("questions_kind_enum", with "kind" "whim" (questionInsert own))
    , ("questions_asker_kind_enum", with "asker_kind" "stranger" (questionInsert own))
    , ("questions_status_enum", with "status" "lost" (questionInsert own))
    ,
        ( "questions_asker_role_iff_subagent"
        , with "asker_role" "researcher" (questionInsert own)
        )
    ,
        ( "questions_asker_run_id_iff_child_run"
        , with "asker_run_id" (runIdText run) (questionInsert own)
        )
    ,
        ( "questions_parked_reason_iff_parked"
        , with "parked_reason" "why" (questionInsert own)
        )
    ,
        ( "rulings_basis_kind_enum"
        , with "basis_kind" "hunch" (rulingInsert (ruled NoBasis))
        )
    ,
        ( "rulings_basis_event_run_id_only_event"
        , with "basis_event_run_id" (runIdText run) (rulingInsert (ruled NoBasis))
        )
    ,
        ( "rulings_basis_event_seq_only_event"
        , withValue "basis_event_seq" (SqlInteger 1) (rulingInsert (ruled NoBasis))
        )
    ,
        ( "rulings_basis_reason_iff_obvious"
        , with "basis_reason" "plain" (rulingInsert (ruled NoBasis))
        )
    , ("answers_reply_kind_enum", with "reply_kind" "shrug" (answerInsert byUser))
    ,
        ( "answers_answerer_kind_enum"
        , with "answerer_kind" "oracle" (answerInsert byUser)
        )
    ,
        ( "answers_answerer_run_id_iff_parent_run"
        , with "answerer_run_id" (runIdText run) (answerInsert byUser)
        )
    , ("gaps_kind_enum", with "kind" "vibe" (gapInsert openGap))
    , ("gaps_severity_enum", with "severity" "mild" (gapInsert openGap))
    , ("gaps_status_enum", with "status" "lost" (gapInsert openGap))
    ,
        ( "gaps_fix_pr_url_iff_fix_proposed_or_fixed"
        , with "fix_pr_url" "https://example.com/p" (gapInsert openGap)
        )
    ,
        ( "gaps_wont_fix_reason_iff_wont_fix"
        , with "wont_fix_reason" "no" (gapInsert openGap)
        )
    , ("gap_evidence_kind_enum", with "kind" "hearsay" urlEvidence)
    ,
        ( "gap_evidence_event_run_id_iff_event"
        , with "event_run_id" (runIdText run) urlEvidence
        )
    ,
        ( "gap_evidence_event_seq_iff_event"
        , withValue "event_seq" (SqlInteger 1) urlEvidence
        )
    , ("gap_evidence_url_iff_url", with "url" "https://example.com/e" eventEvidence)
    , ("artifacts_kind_enum", with "kind" "poem" (artifactInsert urlArtifact))
    ,
        ( "artifacts_location_kind_enum"
        , with "location_kind" "cloud" (artifactInsert urlArtifact)
        )
    , ("artifacts_path_iff_file", with "path" "/a" (artifactInsert urlArtifact))
    , ("artifacts_sha256_iff_file", with "sha256" "00" (artifactInsert urlArtifact))
    ,
        ( "artifacts_size_bytes_iff_file"
        , withValue "size_bytes" (SqlInteger 1) (artifactInsert urlArtifact)
        )
    ,
        ( "artifacts_url_iff_url"
        , with "url" "https://example.com/u" (artifactInsert fileArtifact)
        )
    ,
        ( "artifacts_source_artifact_id_not_self"
        , withValue "source_artifact_id" (SqlInteger 1) (artifactInsert urlArtifact)
        )
    , ("handovers_reason_enum", with "reason" "bored" (handover1 Context))
    , ("stopgaps_value_json", with "value" "{x" (stopgapInsert runStopgap))
    ,
        ( "stopgaps_task_id_iff_breakdown_id"
        , with "task_id" "t0" (stopgapInsert runStopgap)
        )
    ,
        ( "spans_operation_name_enum"
        , with "operation_name" "chat" (spanInsert openSpan)
        )
    , ("spans_status_code_enum", with "status_code" "meh" (spanInsert okSpan))
    , ("spans_handback_token_enum", with "handback_token" "maybe" (spanInsert okSpan))
    ,
        ( "spans_parent_span_id_not_self"
        , withValue "parent_span_id" (SqlInteger 1) (spanInsert openSpan)
        )
    , ("spans_status_code_iff_ended", with "status_code" "ok" (spanInsert openSpan))
    , ("spans_error_type_iff_error", with "error_type" "boom" (spanInsert okSpan))
    ,
        ( "spans_handback_token_only_when_ended"
        , with "handback_token" "ready" (spanInsert openSpan)
        )
    ,
        ( "spans_handback_only_when_ended"
        , with "handback" "READY" (spanInsert openSpan)
        )
    ]
  where
    openGap = GapRow run 1 (Tracked (bareGap "a gap") Gap.Open)
    evidenceOf piece =
        case evidenceInserts
            (GapRow run 1 (Tracked (bareGap "a gap") {evidence = [piece]} Gap.Open)) of
            [row] -> row
            _ -> error "one piece of evidence is one row"
    urlEvidence = evidenceOf (OfUrl (uri "https://example.com/e"))
    eventEvidence = evidenceOf (OfEvent (EventRef run 1))
    urlArtifact =
        ArtifactRow
            run
            1
            (Artifact.Url Artifact.Doc (uri "https://example.com/d"))
            Nothing
            Nothing
    fileArtifact = ArtifactRow run 1 (File (FileArtifact Artifact.Plan fileRef)) Nothing Nothing
    handover1 reason = case handoverInserts (HandoverRow run 1 (Handover reason "s" ("a" :| []))) of
        row : _ -> row
        [] -> error "a hand-over is a row"
    runStopgap =
        StopgapRow
            run
            (StopgapAt Nothing (stopgapKey "a.b"))
            (Stopgap 1 (ijson "1") (titled "r"))
    openSpan = spanRow 1 Nothing Nothing
    okSpan =
        spanRow
            1
            Nothing
            (Just (SpanEnd epoch (WithHandback ReadyWord "READY") unreported))
    active = runState Active Balanced
    stopped = runState (Stopped (Stop minBound "why")) Balanced
    openEpic =
        EpicRow
            run
            (epicNamed "e")
            (Epic.Open (OpenEpic (Repo "o" "r") (Branch "epic/e")))
    planned = taskRow "t0" OnDefault Planned False
    running = taskRow "t0" OnDefault Running True
    untasked = ChildRunRow run 1 (Child run Untasked "/w") Nothing
    hold = TaskHoldRow run 1 (TaskRef (TaskId "t0") 1) (Url "u") HoldOpen
    own = questionRow Pick Itself (Waiting ForTriage)
    ruled = RulingRow run 1 (oneLine "a") (oneLine "w") (oneLine "c")
    byUser = AnswerRow run 1 (Chose "a") TheUser
    with column value = withValue column (SqlText value)
    withValue column value row =
        row
            { values = fmap (\(c, v) -> (c, if c == column then value else v)) row.values
            }

-- | The status column of a row.
statusOf :: Insert -> Maybe Value
statusOf row = lookup "status" (toList row.values)

-- | Every task state, each with its PR.
taskStates :: [TaskState]
taskStates =
    [ InCi u
    , InReview u
    , Round u
    , Merged u
    , Kept u
    , Parked "why" Nothing
    , Parked "why" (Just u)
    , Delivered u
    ]
  where
    u = Url "u"

-- | A task of breakdown 1 with this id, base and progress, its agent at work or not.
taskRow :: Text -> Base -> Progress -> Bool -> TaskRow
taskRow id' base progress =
    TaskRow run 1 (plainTask id' []) {base} progress Nothing

-- | An epic at each stage.
epicRows :: [EpicRow]
epicRows =
    [ EpicRow run (epicNamed "open") (Epic.Open (OpenEpic repo branch))
    , EpicRow run (epicNamed "ready") (Epic.Ready (ReadyEpic repo branch (Url "u")))
    , EpicRow
        run
        (epicNamed "merged")
        (Epic.Merged (MergedEpic repo branch (Url "u")))
    ]
  where
    repo = Repo "o" "r"
    branch = Branch "epic/e"

{- | A task of each progress and base, the first one the others build on,
each at work where its status allows it.
-}
taskRows :: [TaskRow]
taskRows =
    TaskRow run 1 (plainTask "t0" []) Planned (Just sha) False
        : taskRow "e0" (OnEpic (epicNamed "open")) Planned False
        : taskRow "w0" OnDefault Running True
        : zipWith
            ( \i progress -> taskRow ("p" <> Text.pack (show i)) (OnTask (TaskId "t0")) progress False
            )
            [1 :: Int ..]
            (Planned : Running : map Moved taskStates)

-- | A child of each latest token, tasked, and one untasked.
childRunRows :: [ChildRunRow]
childRunRows =
    ChildRunRow run 1 (Child run Untasked "/w") Nothing
        : [ ChildRunRow run 1 (Child run (Tasked (TaskRef (TaskId "t0") 1)) "/w") token
          | token <- Nothing : map Just [minBound .. maxBound]
          ]

-- | A question of each kind, asker and standing.
questionRows :: [QuestionRow]
questionRows =
    [questionRow kind Itself (Waiting ForTriage) | kind <- [minBound .. maxBound]]
        <> [ questionRow Pick from (Waiting ForTriage)
           | from <- [Subagent (AgentRole "researcher"), ChildRun run]
           ]
        <> [ questionRow Pick Itself standing
           | standing <-
                [Waiting ForAnswer, Waiting (ForLater (oneLine "later")), Ruled, Answered']
           ]

-- | The run's question 1, of this kind, asker and standing.
questionRow :: Kind -> Asker -> Standing -> QuestionRow
questionRow kind from =
    QuestionRow
        run
        1
        (Asking (Question (QId run 1) kind (oneLine "q")) (StateName "plan") from)
        kind

-- | A ruling on question 1 on each basis; the question is the last of 'questionRows'.
rulingRows :: [RulingRow]
rulingRows =
    [ RulingRow run 1 (oneLine "a") (oneLine "w") (oneLine "c") basis
    | basis <-
        [ NoBasis
        , OnEvent Nothing
        , OnEvent (Just (EventRef run 2))
        , ObviousFor (oneLine "plain")
        ]
    ]

-- | An answer to question 1 of each reply and answerer.
answerRows :: [AnswerRow]
answerRows =
    [ AnswerRow run 1 reply by
    | reply <- [Chose "a", Other "b"]
    , by <- [TheUser, ParentRun run, TheCaller]
    ]

-- | An open need with no URL, and one with.
userNeedRows :: [UserNeedRow]
userNeedRows =
    [ UserNeedRow run 1 (Need (titled "x") Set.empty Nothing)
    , UserNeedRow
        run
        2
        (Need (titled "y") Set.empty (Just (uri "https://example.com/y")))
    ]

-- | A gap of each status, its evidence of both kinds.
gapRows :: [GapRow]
gapRows =
    [ GapRow run 1 (Tracked gap status)
    | status <-
        [ Gap.Open
        , Gap.FixProposed pr
        , Gap.Closed (Gap.Fixed pr)
        , Gap.Closed (Gap.WontFix (oneLine "not worth it"))
        ]
    ]
  where
    pr = uri "https://github.com/o/r/pull/1"
    gap =
        (bareGap "a gap")
            { evidence = [OfEvent (EventRef run 1), OfUrl (uri "https://example.com/e")]
            }

{- | A span the lead spawned, still running; one under it of each ending,
with every count and none; all at seq 1 to 3 of the engineer run.
-}
spanRows :: [SpanRow]
spanRows =
    spanRow 1 Nothing Nothing
        : spanRow 2 (Just (SpanId 1)) (Just (SpanEnd epoch NoHandback unreported))
        : [ spanRow
                3
                (Just (SpanId 1))
                (Just (SpanEnd epoch (WithHandback word "said") usage))
          | word <- [minBound .. maxBound]
          , usage <- [unreported, Usage (Just 10) (Just 2) (Just 3) (Just 4)]
          ]

-- | The span of this seq, under this parent, and its end.
spanRow :: Natural -> Maybe SpanId -> Maybe SpanEnd -> SpanRow
spanRow n parent =
    SpanRow
        run
        n
        ( SpanStart
            (AgentRole "researcher")
            (Harness "claude-code")
            "a brief"
            parent
            (Just "a-model")
        )
        epoch

{- | A file of each kind and a URL of each, at seq 2: the file made from
seq 1's artifact by span 1, the URL by neither. Span 1 is 'spanRows''.
-}
artifactRows :: [ArtifactRow]
artifactRows =
    ArtifactRow run 1 (File (FileArtifact Artifact.Plan fileRef)) Nothing Nothing
        : [ ArtifactRow run 2 (File (FileArtifact kind fileRef)) (Just 1) (Just (SpanId 1))
          | kind <- [minBound .. maxBound]
          ]
            <> [ ArtifactRow
                    run
                    2
                    (Artifact.Url kind (uri "https://example.com/d"))
                    Nothing
                    Nothing
               | kind <- [minBound .. maxBound]
               ]

-- | The run's stopgap, and a task's.
stopgapRows :: [StopgapRow]
stopgapRows =
    [ StopgapRow
        run
        place
        (Stopgap n (ijson "{\"a\":[1,\"x\"]}") (titled "no event fits"))
    | (n, place) <- zip [1 ..] stopgapPool
    ]

refusedBy :: Text -> Either SQLError () -> Bool
refusedBy message = \case
    Left e -> message `Text.isInfixOf` e.sqlErrorDetails
    Right () -> False

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 11 13) 0

-- | A 10x run, by the seq of each line: its tasks, children, holds and questions.
tenXRun :: NonEmpty Envelope
tenXRun =
    NonEmpty.zipWith
        (\n (source, event) -> (line n event) {source})
        (1 :| [2 ..])
        ( (Cli, Started start {Started.flow = TenXFlow})
            :| map
                (Cli,)
                [ fuelSet Balanced
                , EpicMoved e1 (Opens (Repo "o" "r") (Branch "epic/e1"))
                , Overridden (StateName "breakdown") "the plan is agreed"
                , stepTook (BreakdownDone engineers (tasksOf (t1 :| [t2])))
                ]
            <> [
                   ( Hook (Digest spawnDigest)
                   , Spawned (Child c1 (Tasked (TaskRef (TaskId "t1") 5)) "/w/c1")
                   )
               ]
            <> map
                (Cli,)
                [ Held (TaskRef (TaskId "t1") 5) (Url "u1")
                , Held (TaskRef (TaskId "t1") 5) (Url "u2")
                , HandedBack c1 (Just (TaskRef (TaskId "t1") 5)) (Ended (Stop Replan "re-plan"))
                , ActedOn (TaskRef (TaskId "t1") 5) (Url "u1")
                , asked 11 Pick Itself
                , RuledOn (q 11) (ruling (Just (AnsweredBy (Hashed (Digest spawnDigest)))))
                , asked 13 Pick Itself
                , RuledOn (q 13) (ruling (Just (AnsweredBy (Hashed (Digest "00000000deadbeef")))))
                , asked 15 Design (Subagent (AgentRole "researcher"))
                , Forwarded (q 15) TheUser
                , Answered (q 15) (Chose "yes") TheUser
                , Overridden (StateName "breakdown") "re-plan"
                , stepTook (BreakdownDone engineers (tasksOf (plainTask "t3" [] :| [])))
                , TaskMoved (TaskRef (TaskId "t3") 19) (Delivered (Url "u3"))
                , UserNeeded
                    ( Need
                        (titled "add the secret")
                        (Set.singleton (TaskRef (TaskId "t3") 19))
                        (Just (uri "https://example.com/s"))
                    )
                , asked 22 Scope Itself
                , Forwarded (q 22) TheUser
                , QuestionParked (q 22) (oneLine "after the release")
                , asked 25 Confirm Itself
                , Event.Stopped (Stop Blocked "out of options")
                ]
        )
  where
    e1 = epicNamed "e1"
    t1 = (plainTask "t1" []) {base = OnEpic e1}
    t2 = (plainTask "t2" ["t1"]) {base = OnTask (TaskId "t1")}
    q = QId run
    asked n kind from =
        Asked
            (Asking (Question (q n) kind (oneLine "which way?")) (StateName "engineers") from)
    ruling = Proposal (oneLine "this way") (oneLine "it fits") (oneLine "none")

-- | The store's text of the time of 'contextRun''s line at this seq.
at' :: Natural -> Maybe Value
at' n = Just (SqlText (Field.encode Field.time (line n started).ts))

-- | The digest of 'tenXRun''s @spawned@ line, a hook's.
spawnDigest :: Text
spawnDigest = "000000005ca1ab1e"

-- | The child run 'tenXRun' spawns, which a store holds beside it.
c1 :: RunId
c1 = runId "c1aa"

childRun :: NonEmpty Envelope
childRun = lineOf c1 1 started :| []
