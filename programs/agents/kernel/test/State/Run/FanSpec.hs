module State.Run.FanSpec (spec) where

import Data.Either (fromRight, isRight)
import Data.Foldable (for_, toList)
import Data.List (inits)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (Gen, assert, cover, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Run.Ask (QId (..))
import State.Run.Event
import State.Run.EventGen (
    genSaid,
    genTaskAt,
    genTaskId,
    genTaskState,
    genTasks,
    oneLine,
    runId,
    tasksOf,
 )
import State.Run.Fan hiding (merged, tasksOf)
import State.Run.Fan qualified as Fan (tasksOf)
import State.Run.RunGen (plainTask)
import State.Step.Artifact qualified as Artifact (Task (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Fan" $ do
    it "spawnable_respects_deps_and_agents" . hedgehog $ do
        fan <- forAll genFan
        let picks = spawnable [] fan
            busy =
                [ task
                | task <- Fan.tasksOf fan
                , Set.member task.id fan.atWork
                    || Tasked task.id `elem` map (childTaskId . (.child)) (running fan)
                ]
        cover 10 "spawns some" (not (null picks))
        for_ picks $ \task -> do
            assert (not (settled fan task.id))
            assert (task.id `notElem` map (.id) busy)
            assert (all (merged fan) task.deps)
            assert (Tasked task.id `notElem` map (childTaskId . fst) (untriaged fan))
            assert (not (awaitsCi fan task.id))

    it "spawning_or_starting_every_spawnable_task_leaves_none_to_spawn" . hedgehog $ do
        fan <- forAll genFan
        let picks = zip [0 :: Int ..] (spawnable [] fan)
            spawnedAll =
                foldl'
                    ( \current (n, task) -> fromRight current (spawned [] (childFor ("new" <> tshow n) task.id) current)
                    )
                    fan
                    picks
            spawningAll =
                foldl'
                    (\current (_, task) -> fromRight current (spawning [] task.id current))
                    fan
                    picks
        (spawnable [] spawnedAll, spawnable [] spawningAll) === ([], [])

    it "spawns every independent task at once, heavy or not" $ do
        let five =
                fresh
                    ( tasksOf
                        ( (plainTask "t1" []) {heavy = True}
                            :| [ (plainTask "t2" []) {heavy = True}
                               , plainTask "t3" []
                               , plainTask "t4" []
                               , plainTask "t5" []
                               ]
                        )
                    )
        map (.id) (spawnable [] five)
            `shouldBe` map TaskId ["t1", "t2", "t3", "t4", "t5"]
        length . (.atWork)
            <$> foldl'
                (\fan task -> fan >>= spawning [] task.id)
                (Right five)
                (Fan.tasksOf five)
            `shouldBe` Right 5

    it "settles a task whose child finished" $
        settledAfter
            [ spawned [] (childFor "c1" t1)
            , handedBack (runId "c1") (Finished (oneLine "PR #1"))
            ]
            `shouldBe` Right True

    it
        "keeps a finished task open while its PR is in CI, awaits that CI, and builds it no more"
        $ do
            let fan =
                    applied
                        [ spawned [] (childFor "c1" t1)
                        , handedBack (runId "c1") (Finished (oneLine "PR #1"))
                        , moved t1 (InCi (Url "pr"))
                        ]
            (\f -> (settled f t1, map (.id) (spawnable [] f), ciAwaited f)) <$> fan
                `shouldBe` Right (False, [], [Url "pr"])

    it "settles a task in CI once it is recorded in review" $
        settledAfter
            [ spawned [] (childFor "c1" t1)
            , handedBack (runId "c1") (Finished (oneLine "PR #1"))
            , moved t1 (InCi (Url "pr"))
            , moved t1 (InReview (Url "pr"))
            ]
            `shouldBe` Right True

    it
        "leaves a task open after its child stops, to spawn again once the stop is triaged, and counts both tries"
        $ do
            let fan =
                    applied
                        [ spawned [] (childFor "c1" t1)
                        , handedBack (runId "c1") (Ended (Stop Blocked "no access"))
                        ]
            map (.id) . spawnable [] <$> fan `shouldBe` Right []
            (fan >>= spawning [] t1) `shouldBe` Left (StopUntriaged (runId "c1"))
            map (.id) . spawnable [] . triaged (runId "c1") <$> fan `shouldBe` Right [t1]
            (`tries` t1)
                <$> (fan >>= spawning [] t1 . triaged (runId "c1") >>= spawned [] (childFor "c2" t1))
                `shouldBe` Right 2

    it "retries no task while its stopped child's question is open" $ do
        let fan =
                triaged (runId "c1")
                    <$> applied
                        [ spawned [] (childFor "c1" t1)
                        , handedBack (runId "c1") (Ended (Stop Blocked "no access"))
                        ]
            asking = [runId "c1"]
        map (.id) . spawnable asking <$> fan `shouldBe` Right []
        (fan >>= spawning asking t1) `shouldBe` Left (AwaitsUser (runId "c1"))
        (fan >>= spawned asking (childFor "c2" t1))
            `shouldBe` Left (AwaitsUser (runId "c1"))

    it "refuses a child's init on a task whose last stop is not triaged" $
        applied
            [ spawned [] (childFor "c1" t1)
            , handedBack (runId "c1") (Ended (Stop Blocked "no access"))
            , spawned [] (childFor "c2" t1)
            ]
            `shouldBe` Left (StopUntriaged (runId "c1"))

    it "refuses a second spawn of a task an agent works on" $
        applied [spawning [] t1, spawning [] t1] `shouldBe` Left (AtWork t1)

    it "refuses to resume a child twice before it hands back" $
        applied
            [ spawned [] (childFor "c1" t1)
            , handedBack (runId "c1") (Awaits Ci (oneLine "PR #1"))
            , resumed (runId "c1")
            , resumed (runId "c1")
            ]
            `shouldBe` Left (AtWork t1)

    it "closes only once every task is merged or parked" $
        map
            (\state -> applied [moved t1 state] >>= closed)
            [InReview (Url "pr"), Merged (Url "pr")]
            `shouldBe` [Left (Unmerged (t1 :| [])), Right ()]

    it "keeps a child running while it asks up or awaits CI" $
        length . running
            <$> applied
                [ spawned [] (childFor "c1" t1)
                , handedBack (runId "c1") (Awaits Ci (oneLine "PR #1"))
                ]
            `shouldBe` Right 1

    it "finds the child a question came from while that question is its latest word" $ do
        let asks = QId (runId "c1") 1
            asked = [spawned [] (childFor "c1" t1), handedBack (runId "c1") (AsksUp asks)]
        map
            (fmap (fmap (.child.run) . (`askedBy` asks)) . applied)
            [asked, asked <> [handedBack (runId "c1") (Finished (oneLine "PR #1"))]]
            `shouldBe` [Right (Just (runId "c1")), Right Nothing]

    it "settles a parked task, so the fan-out may leave" $
        (applied [moved t1 (Parked "out of scope" Nothing)] >>= leave)
            `shouldBe` Right ()

    it "runs a parked task again once an agent or a child takes it" $
        map
            ( fmap (\fan -> (settled fan t1, allParked fan))
                . applied
                . (moved t1 (Parked "later" Nothing) :)
                . pure
            )
            [spawning [] t1, spawned [] (childFor "c1" t1)]
            `shouldBe` replicate 2 (Right (False, False))

    it "respawns a parked task whose last child stopped: parking settled the stop" $
        map
            ( fmap (`tries` t1)
                . applied
                . ( [ spawned [] (childFor "c1" t1)
                    , handedBack (runId "c1") (Ended (Stop Blocked "no access"))
                    , moved t1 (Parked "later" Nothing)
                    ]
                        <>
                  )
            )
            [ [spawning [] t1, spawned [] (childFor "c2" t1)]
            , [spawned [] (childFor "c2" t1)]
            ]
            `shouldBe` replicate 2 (Right 2)

    it "does not leave while a child runs on a task already in review" $
        ( applied
            [ spawned [] (childFor "c1" t1)
            , handedBack (runId "c1") (Awaits Ci (oneLine "PR #1"))
            , moved t1 (InReview (Url "pr"))
            ]
            >>= leave
        )
            `shouldBe` Left (Unsettled (t1 :| []))

    it "does not settle a task whose PR is in CI" $
        (applied [moved t1 (InCi (Url "pr"))] >>= leave)
            `shouldBe` Left (Unsettled (t1 :| []))

    it "refuses a second child for a task whose child runs" $
        applied [spawned [] (childFor "c1" t1), spawned [] (childFor "c2" t1)]
            `shouldBe` Left (StillRunning t1 (runId "c1"))

    it "refuses a hand-back from a child that finished" $
        applied
            [ spawned [] (childFor "c1" t1)
            , handedBack (runId "c1") (Finished (oneLine "PR"))
            , handedBack (runId "c1") (Finished (oneLine "PR"))
            ]
            `shouldBe` Left (ChildOver (runId "c1"))

    it "refuses a hand-back from a child never spawned" $
        applied [handedBack (runId "c9") (Finished (oneLine "PR"))]
            `shouldBe` Left (UnknownChild (runId "c9"))

    it "refuses a task the breakdown lacks" $
        applied [held (TaskId "t9") (Url "u")]
            `shouldBe` Left (UnknownTask (TaskId "t9"))

    it "spawns a task only once its dependency merged, not while it is in review" $ do
        let reviewed =
                spawned [] (childFor "c1" t1) twoTasks
                    >>= handedBack (runId "c1") (Finished (oneLine "PR"))
                    >>= moved t1 (InReview (Url "pr"))
        map (.id) (spawnable [] twoTasks) `shouldBe` [t1]
        map (.id) . spawnable [] <$> reviewed `shouldBe` Right []
        map (.id) . spawnable [] <$> (reviewed >>= moved t1 (Merged (Url "pr")))
            `shouldBe` Right [t2]

    it "keeps_a_merged_task_merged_ignoring_any_later_move" . hedgehog $ do
        later <- forAll genTaskState
        let merged' = applied [moved t1 (Merged (Url "pr"))]
        (merged' >>= moved t1 later) === merged'

    it "awaits the merge of a dependency in review" $
        mergesAwaited <$> moved t1 (InReview (Url "pr")) twoTasks `shouldBe` Right [t1]

    it "leaves the fan-out with its tasks idle in review" $
        (applied [moved t1 (InReview (Url "pr"))] >>= leave) `shouldBe` Right ()

    it "spawns no task whose dependency is parked: it never merges" $
        map (.id) . spawnable [] <$> moved t1 (Parked "out of scope" Nothing) twoTasks
            `shouldBe` Right []

    it "counts the fan-out all parked only once every task is" $
        map
            (fmap allParked)
            [ moved t1 (Parked "out of scope" Nothing) twoTasks
            , moved t1 (Parked "a" Nothing) twoTasks >>= moved t2 (Parked "b" Nothing)
            ]
            `shouldBe` [Right False, Right True]

    describe "an added task" $ do
        it "is spawnable at once, its dependencies merged" $
            map (.id) . spawnable []
                <$> (moved t1 (Merged (Url "pr")) oneTask >>= added 1 (plainTask "fix" ["t1"]))
                `shouldBe` Right [TaskId "fix"]

        it "waits for its dependency's merge as any task" $
            map (.id) . spawnable []
                <$> (spawning [] t1 oneTask >>= added 1 (plainTask "fix" ["t1"]))
                `shouldBe` Right []

        it "keeps the fan-out open until it settles" $
            (moved t1 (Merged (Url "pr")) oneTask >>= added 1 (plainTask "fix" []) >>= leave)
                `shouldBe` Left (Unsettled (TaskId "fix" :| []))

        it "is refused under an id the fan-out has" $
            added 1 (plainTask "t1" []) oneTask `shouldBe` Left (TaskExists t1)

        it "is refused depending on a task the fan-out lacks" $
            added 1 (plainTask "fix" ["t9"]) oneTask
                `shouldBe` Left (UnknownTask (TaskId "t9"))

        it "is refused based on a task the fan-out lacks" $
            added 1 (plainTask "fix" []) {Artifact.base = OnTask (TaskId "t9")} oneTask
                `shouldBe` Left (UnknownTask (TaskId "t9"))

        it "joins the breakdown's seq, or with none starts one at its own" $
            map
                (fmap (fmap (.seq) . (.breakdown)) . added 7 (plainTask "fix" []))
                [oneTask, emptyFan]
                `shouldBe` [Right (Just 1), Right (Just 7)]

    describe "a delivered task" $ do
        let delivered = moved t1 (Delivered (Url "pr")) twoTasks
        it "is settled, so the fan-out may leave and its round end" $
            ( delivered >>= moved t2 (Delivered (Url "pr2")) >>= \fan -> (,) <$> leave fan <*> closed fan
            )
                `shouldBe` Right ((), ())
        it "is not merged: its dependents are not spawned" $
            map (.id) . spawnable [] <$> delivered `shouldBe` Right []
        it "awaits no merge" $
            mergesAwaited <$> delivered `shouldBe` Right []
        it "names its PR" $
            (`pullRequest` t1) <$> delivered `shouldBe` Right (Just (Url "pr"))

    describe "a base change" $ do
        it "replaces the task's base, and only its" $
            map (.base) . Fan.tasksOf <$> rebased t2 (OnTask t1) twoTasks
                `shouldBe` Right [OnDefault, OnTask t1]
        it "is refused on a task the breakdown lacks" $
            rebased (TaskId "t9") OnDefault twoTasks
                `shouldBe` Left (UnknownTask (TaskId "t9"))
        it "is refused naming the task itself or a later one" $
            map (\on -> rebased t1 (OnTask on) twoTasks) [t1, t2]
                `shouldBe` [Left (UnknownTask t1), Left (UnknownTask t2)]
        it "leaves_no_base_or_dependency_naming_a_task_not_before_it" . hedgehog $ do
            fan <- forAll (fresh <$> genTasks)
            let ids = map (.id) (Fan.tasksOf fan)
            changes <-
                forAll
                    ( Gen.list
                        (Range.linear 0 6)
                        ( (,)
                            <$> Gen.element ids
                            <*> Gen.choice [pure OnDefault, OnTask <$> Gen.element ids]
                        )
                    )
            let after =
                    foldl' (\now (task, base) -> fromRight now (rebased task base now)) fan changes
                placed = zip (inits (map (.id) (Fan.tasksOf after))) (Fan.tasksOf after)
            cover 5 "a base change taken" (after /= fan)
            assert
                ( and
                    [ all (`elem` before) (task.deps <> toList (builtOn task.base))
                    | (before, task) <- placed
                    ]
                )

    it "keeps the head a task's branch was last seen at" $
        Map.lookup t1 . (.heads)
            <$> (headed t1 (Sha "a") oneTask >>= headed t1 (Sha "b"))
            `shouldBe` Right (Just (Sha "b"))

    describe "a round on a task's PR" $ do
        let finishedInReview =
                applied
                    [ spawned [] (childFor "c1" t1)
                    , handedBack (runId "c1") (Finished (oneLine "PR"))
                    , moved t1 (InReview (Url "pr"))
                    ]
            round1 = finishedInReview >>= moved t1 (Round (Url "pr"))

        it "un-settles the task in review, so it is spawned again" $ do
            ((`settled` t1) <$> round1, map (.id) . spawnable [] <$> round1)
                `shouldBe` (Right False, Right [t1])

        it "makes the task a round on that PR, so its child's READY keeps it" $ do
            fmap (.shape) . (`lookupTask` t1) <$> round1
                `shouldBe` Right (Just (RoundOn (Url "pr")))
            ( (`settled` t1)
                    <$> ( round1
                            >>= spawned [] (childFor "c2" t1)
                            >>= handedBack (runId "c2") (Finished (oneLine "READY"))
                            >>= moved t1 (Kept (Url "pr"))
                        )
                )
                `shouldBe` Right True

        it "counts the rounds asked of each task" $
            Map.lookup t1 . (.rounds) <$> (round1 >>= moved t1 (Round (Url "pr")))
                `shouldBe` Right (Just 2)

        it "is refused while a child runs the task" $
            applied [spawned [] (childFor "c1" t1), moved t1 (Round (Url "pr"))]
                `shouldBe` Left (StillRunning t1 (runId "c1"))

        it "is refused while an agent is at work on the task" $
            applied [spawning [] t1, moved t1 (Round (Url "pr"))]
                `shouldBe` Left (AtWork t1)

    describe "a restart" $ do
        it "leaves no agent at work, so each running child waits on the 10x" . hedgehog $ do
            fan <- forAll genFan
            let after = restarted fan
            (Set.toList after.atWork, map (.child.run) (waiting after))
                === ([], map (.child.run) (running fan))

        it "frees a task whose spawned agent never started its child" $
            map (.id) . spawnable [] . restarted <$> spawning [] t1 oneTask
                `shouldBe` Right [t1]

    describe "a new breakdown" $ do
        it "starts a fresh fan-out" $
            ( spawned [] (childFor "c1" t1) independent
                >>= handedBack (runId "c1") (Finished (oneLine "PR"))
                >>= moved t1 (Merged (Url "pr"))
                >>= broken 1 (tasksOf (plainTask "t3" [] :| []))
            )
                `shouldBe` Right (fresh (tasksOf (plainTask "t3" [] :| [])))

        it "is refused while an agent is at work" $
            ( spawning [] t1 independent
                >>= spawned [] (childFor "c2" t2)
                >>= broken 1 (tasksOf (plainTask "t3" [] :| []))
            )
                `shouldBe` Left (Busy (t1 :| [t2]))

    describe "breakdown" $ do
        it "refuses a task named twice" $
            breakdown (plainTask "t1" [] :| [plainTask "t1" []])
                `shouldBe` Left (TaskTwice t1)

        it "refuses a dependency on a later task, so dependencies never cycle" $
            breakdown (plainTask "t1" ["t2"] :| [plainTask "t2" []])
                `shouldBe` Left (DependsLater t1 t2)

        it
            "accepts_a_breakdown_only_if_no_dependency_or_base_names_a_task_not_before_it"
            . hedgehog
            $ do
                tasks <- forAll genLoose
                let ids = map (.id) (toList tasks)
                    placed = zip (inits ids) (toList tasks)
                    earlierOnly =
                        and
                            [ task.id `notElem` before
                                && all (`elem` before) (task.deps <> toList (builtOn task.base))
                            | (before, task) <- placed
                            ]
                    baseLater =
                        or
                            [ any (`notElem` before) (builtOn task.base)
                            | (before, task) <- placed
                            ]
                cover 10 "accepted" earlierOnly
                cover 10 "refused" (not earlierOnly)
                cover 5 "a base on a task not before it" baseLater
                isRight (breakdown tasks) === earlierOnly
  where
    settledAfter changes = (`settled` t1) <$> applied changes
    applied = foldl' (>>=) (Right oneTask)
    oneTask = fresh (tasksOf (plainTask "t1" [] :| []))
    -- @t2@ depends on @t1@.
    twoTasks = fresh (tasksOf (plainTask "t1" [] :| [plainTask "t2" ["t1"]]))
    independent = fresh (tasksOf (plainTask "t1" [] :| [plainTask "t2" []]))

t1, t2 :: TaskId
t1 = TaskId "t1"
t2 = TaskId "t2"

childFor :: Text.Text -> TaskId -> Child
childFor child taskId = Child (runId child) (Tasked (TaskRef taskId 1)) "worktree"

-- | A breakdown's fan-out, logged at seq 1: a first breakdown has no agent at work to refuse it.
fresh :: Tasks -> Fan
fresh tasks = either (error . show) id (broken 1 tasks emptyFan)

-- | The task's PR merged.
merged :: Fan -> TaskId -> Bool
merged fan task = case Map.lookup task fan.moves of
    Just (Merged _) -> True
    Just (Parked _ _) -> False
    Just (InReview _) -> False
    Just (InCi _) -> False
    Just (Kept _) -> False
    Just (Round _) -> False
    Just (Delivered _) -> False
    Nothing -> False

-- | The task's PR is in CI after its latest child finished: CI is awaited, nothing built again.
awaitsCi :: Fan -> TaskId -> Bool
awaitsCi fan task = case ( Map.lookup task fan.moves
                         , latest =<< listToMaybe (reverse (childrenOf fan task))
                         ) of
    (Just (InCi _), Just (Finished _)) -> True
    _ -> False

tshow :: Int -> Text.Text
tshow = Text.pack . show

{- | A breakdown's tasks as 'genTasks' makes them, or up to four tasks of
ids @t1@ to @t5@ in any order, each depending on and based on any of them:
the breakdown decides which may stand.
-}
genLoose :: Gen (NonEmpty Task)
genLoose =
    Gen.choice [tasksInOrder <$> genTasks, Gen.nonEmpty (Range.linear 1 4) genAny]
  where
    genAny = do
        task <- Gen.int (Range.linear 1 5) >>= genTaskAt
        deps <- Gen.choice [pure [], Gen.subsequence ids]
        base <- Gen.choice [pure OnDefault, OnTask <$> Gen.element ids, pure task.base]
        name <- Gen.element ids
        pure task {Artifact.id = name, Artifact.deps = deps, Artifact.base = base}
    ids = map (TaskId . ("t" <>) . Text.pack . show) [1 :: Int .. 5]

-- | A breakdown, then spawns, hand-backs and moves, each kept only where the fan accepts it.
genFan :: Gen Fan
genFan = do
    tasks <- genTasks
    changes <- Gen.list (Range.linear 0 25) genChange
    pure
        ( foldl'
            (\fan (n, change) -> fromRight fan (change n fan))
            (fresh tasks)
            (zip [0 :: Int ..] changes)
        )
  where
    genChange =
        Gen.choice
            [ (\taskId n -> spawned [] (childFor ("c" <> tshow n) taskId)) <$> genTaskId
            , ( \i said _ fan -> case fan.children of
                    [] -> Right fan
                    children -> handedBack (children !! (i `mod` length children)).child.run said fan
              )
                <$> Gen.int (Range.linear 0 10)
                <*> genSaid
            , (\taskId state _ -> moved taskId state) <$> genTaskId <*> genTaskState
            , (\taskId _ -> spawning [] taskId) <$> genTaskId
            , (\i _ fan -> Right (triaged (pickChild i fan) fan))
                <$> Gen.int (Range.linear 0 10)
            , (\i _ fan -> resumed (pickChild i fan) fan) <$> Gen.int (Range.linear 0 10)
            , (\task _ -> added 1 task) <$> (Gen.int (Range.linear 1 7) >>= genTaskAt)
            , pure (\_ fan -> Right (restarted fan))
            ]
    pickChild i fan = case fan.children of
        [] -> runId "none"
        children -> (children !! (i `mod` length children)).child.run
