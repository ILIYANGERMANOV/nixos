{- | The projections in a real store: made at open as SQLite keeps their
DDL, rebuilt whole and once when stale, replaced in each append to the rows
a full rebuild makes, which are the rows the fold makes.
-}
module Effects.Store.ProjectionSpec (spec) where

import Concurrently (bothAtOnce)
import Control.Exception (try)
import Data.Either (isRight)
import Data.Foldable (for_, toList, traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Payload.Event (eventRow, runRow)
import Data.Payload.Upcast (shipped)
import Data.Projection (
    Insert (..),
    Projection (..),
    Projections (..),
    Table (..),
    Value (..),
 )
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
import Hedgehog (Gen, assert, cover, evalIO, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Numeric.Natural (Natural)
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
    Need (..),
    Repo (..),
    RunId,
    Said (Ended),
    Source (..),
    Stop (..),
    StopReason (..),
    Task (..),
    TaskId (..),
    TaskRef (..),
    TaskState (..),
    Url (..),
    runIdText,
    stepTook,
 )
import State.Run.Event qualified as Event
import State.Run.Event qualified as Started (Start (..))
import State.Run.EventGen (
    epicNamed,
    fuelSet,
    genOneLine,
    genProposal,
    genReply,
    line,
    lineOf,
    oneLine,
    run,
    runId,
    start,
    started,
    tasksOf,
    titled,
    uri,
 )
import State.Run.Fold (Pending (..), RunState (..), Waits (..))
import State.Run.Fold qualified as Fold
import State.Run.Id (Digest (..), EventId (..), EventRef (..))
import State.Run.RunGen (g, genAccepted, happyPath, plainTask, sha)
import State.Step.Fan (Outcome (BreakdownDone), engineers)
import System.FilePath ((</>))
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

    modifyMaxSuccess (const 50) $ do
        it "keeps, after each append, the rows a full rebuild makes" . hedgehog $ do
            logged <- forAll (genAccepted >>= asking)
            let tables = map (.table) (Registry.rows logged)
            cover 2 "a round with problems" ("round_problems" `elem` tables)
            cover 5 "a ruling" ("rulings" `elem` tables)
            cover 5 "an answer" ("answers" `elem` tables)
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

{- | The log of these events with questions put between them: asked,
retagged, ruled on, forwarded, answered or parked, each where the fold
takes it, and at times a stop at its end. An event the fold refuses after a
question ends the log there.
-}
asking :: [Event] -> Gen (NonEmpty Envelope)
asking events = do
    let first = line 1 started
    (rest, ended) <- go (replayed (first :| [])) 2 events
    stop <- Gen.element [[], [Event.Stopped (Stop Blocked "stuck")]]
    pure (first :| rest <> [line (ended + 1) event | ended > 1, event <- stop])
  where
    replayed = either (error . show) id . Fold.replay g
    go state n pending' = do
        question <- Gen.frequency [(3, pure Nothing), (1, Just <$> questionOn state n)]
        case (question, pending') of
            (Just event, _)
                | Right (Fold.Appended next) <- Fold.append g state (line n event) ->
                    first' (line n event :) <$> go next (n + 1) pending'
            (_, event : rest) -> case Fold.append g state (line n event) of
                Right (Fold.Appended next) -> first' (line n event :) <$> go next (n + 1) rest
                Right Fold.AlreadyLogged -> pure ([], n - 1)
                Left _ -> pure ([], n - 1)
            (_, []) -> pure ([], n - 1)
    first' f (xs, n) = (f xs, n)
    questionOn state n =
        Gen.choice
            ( ( ( \kind text from ->
                    Asked (Asking (Question (QId run n) kind text) (Fold.nodeName state.at) from)
                )
                    <$> Gen.enumBounded
                    <*> genOneLine
                    <*> Gen.element [Itself, Subagent (AgentRole "researcher")]
              )
                : [ Gen.choice
                        [ pure (Event.RetaggedSecurity qid)
                        , RuledOn qid <$> genProposal
                        , pure (Forwarded qid TheUser)
                        , (\reply -> Answered qid reply TheUser) <$> genReply
                        , QuestionParked qid <$> genOneLine
                        ]
                  | open <- take 1 (reverse state.pending)
                  , let qid = open.asking.question.qid
                  ]
            )

-- | A question of the log's is pending when its stop ends it.
stopEnded :: NonEmpty Envelope -> Bool
stopEnded logged = case (NonEmpty.last logged).event of
    Event.Stopped _ -> any (\(_, state) -> not (null state.pending)) (lastTwo logged)
    _ -> False
  where
    lastTwo = either (const []) (take 1 . drop 1 . reverse . toList) . Fold.trace g

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
    ]
  where
    active = runState Active Nothing Balanced
    stopped = runState Stopped (Just (Stop minBound "why")) Balanced
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

-- | The digest of 'tenXRun''s @spawned@ line, a hook's.
spawnDigest :: Text
spawnDigest = "000000005ca1ab1e"

-- | The child run 'tenXRun' spawns, which a store holds beside it.
c1 :: RunId
c1 = runId "c1aa"

childRun :: NonEmpty Envelope
childRun = lineOf c1 1 started :| []
