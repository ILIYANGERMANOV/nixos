module State.Run.FanSpec (spec) where

import Data.Either (fromRight)
import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (Gen, assert, cover, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Run.Event
import State.Run.EventGen (genSaid, genTaskId, genTaskState, genTasks, oneLine, runId, tasksOf)
import State.Run.Fan
import State.Run.RunGen (plainTask)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Fan" $ do
    it "spawnable_respects_deps_and_agents" . hedgehog $ do
        fan <- forAll genFan
        let picks = spawnable [] fan
            busy = [task | task <- fan.tasks, Set.member task.id fan.atWork || task.id `elem` map (.child.task) (running fan)]
        cover 10 "spawns some" (not (null picks))
        for_ picks $ \task -> do
            assert (not (settled fan task.id))
            assert (task.id `notElem` map (.id) busy)
            assert (all (merged fan) task.deps)
            assert (task.id `notElem` map ((.task) . fst) (untriaged fan))

    it "spawning_or_starting_every_spawnable_task_leaves_none_to_spawn" . hedgehog $ do
        fan <- forAll genFan
        let picks = zip [0 :: Int ..] (spawnable [] fan)
            spawnedAll = foldl' (\current (n, task) -> fromRight current (spawned [] (childFor ("new" <> tshow n) task.id) current)) fan picks
            spawningAll = foldl' (\current (_, task) -> fromRight current (spawning [] task.id current)) fan picks
        (spawnable [] spawnedAll, spawnable [] spawningAll) === ([], [])

    it "spawns every independent task at once, heavy or not" $ do
        let five = fresh (tasksOf ((plainTask "t1" []) {heavy = True} :| [(plainTask "t2" []) {heavy = True}, plainTask "t3" [], plainTask "t4" [], plainTask "t5" []]))
        map (.id) (spawnable [] five) `shouldBe` map TaskId ["t1", "t2", "t3", "t4", "t5"]
        length . (.atWork) <$> foldl' (\fan task -> fan >>= spawning [] task.id) (Right five) five.tasks `shouldBe` Right 5

    it "settles a task whose child finished" $
        settledAfter [spawned [] (childFor "c1" t1), handedBack (runId "c1") (Finished (oneLine "PR #1"))] `shouldBe` Right True

    it "leaves a task open after its child stops, to spawn again once the stop is triaged, and counts both tries" $ do
        let fan = applied [spawned [] (childFor "c1" t1), handedBack (runId "c1") (Ended (Stop Blocked "no access"))]
        map (.id) . spawnable [] <$> fan `shouldBe` Right []
        (fan >>= spawning [] t1) `shouldBe` Left (StopUntriaged (runId "c1"))
        map (.id) . spawnable [] . triaged (runId "c1") <$> fan `shouldBe` Right [t1]
        (`tries` t1) <$> (fan >>= spawning [] t1 . triaged (runId "c1") >>= spawned [] (childFor "c2" t1)) `shouldBe` Right 2

    it "retries no task while its stopped child's question is open" $ do
        let fan = triaged (runId "c1") <$> applied [spawned [] (childFor "c1" t1), handedBack (runId "c1") (Ended (Stop Blocked "no access"))]
            asking = [runId "c1"]
        map (.id) . spawnable asking <$> fan `shouldBe` Right []
        (fan >>= spawning asking t1) `shouldBe` Left (AwaitsUser (runId "c1"))
        (fan >>= spawned asking (childFor "c2" t1)) `shouldBe` Left (AwaitsUser (runId "c1"))

    it "refuses a child's init on a task whose last stop is not triaged" $
        applied [spawned [] (childFor "c1" t1), handedBack (runId "c1") (Ended (Stop Blocked "no access")), spawned [] (childFor "c2" t1)]
            `shouldBe` Left (StopUntriaged (runId "c1"))

    it "refuses a second spawn of a task an agent works on" $
        applied [spawning [] t1, spawning [] t1] `shouldBe` Left (AtWork t1)

    it "refuses to resume a child twice before it hands back" $
        applied [spawned [] (childFor "c1" t1), handedBack (runId "c1") (AwaitsCi (oneLine "PR #1")), resumed (runId "c1"), resumed (runId "c1")]
            `shouldBe` Left (AtWork t1)

    it "closes only once every task is merged or parked" $
        map (\state -> applied [moved t1 state] >>= closed) [InReview (Url "pr"), Merged (Url "pr")] `shouldBe` [Left (Unmerged (t1 :| [])), Right ()]

    it "keeps a child running while it asks up or awaits CI" $
        length . running <$> applied [spawned [] (childFor "c1" t1), handedBack (runId "c1") (AwaitsCi (oneLine "PR #1"))] `shouldBe` Right 1

    it "settles a parked task, so the fan-out may leave" $
        (applied [moved t1 (Parked "out of scope" Nothing)] >>= leave) `shouldBe` Right ()

    it "does not leave while a child runs on a task already in review" $
        (applied [spawned [] (childFor "c1" t1), handedBack (runId "c1") (AwaitsCi (oneLine "PR #1")), moved t1 (InReview (Url "pr"))] >>= leave)
            `shouldBe` Left (Unsettled (t1 :| []))

    it "does not settle a task whose PR is in CI" $
        (applied [moved t1 (InCi (Url "pr"))] >>= leave) `shouldBe` Left (Unsettled (t1 :| []))

    it "refuses a second child for a task whose child runs" $
        applied [spawned [] (childFor "c1" t1), spawned [] (childFor "c2" t1)] `shouldBe` Left (StillRunning t1 (runId "c1"))

    it "refuses a hand-back from a child that finished" $
        applied [spawned [] (childFor "c1" t1), handedBack (runId "c1") (Finished (oneLine "PR")), handedBack (runId "c1") (Finished (oneLine "PR"))]
            `shouldBe` Left (ChildOver (runId "c1"))

    it "refuses a hand-back from a child never spawned" $
        applied [handedBack (runId "c9") (Finished (oneLine "PR"))] `shouldBe` Left (UnknownChild (runId "c9"))

    it "refuses a task the breakdown lacks" $
        applied [held (TaskId "t9") (Url "u")] `shouldBe` Left (UnknownTask (TaskId "t9"))

    it "spawns a task only once its dependency merged, not while it is in review" $ do
        let reviewed = spawned [] (childFor "c1" t1) twoTasks >>= handedBack (runId "c1") (Finished (oneLine "PR")) >>= moved t1 (InReview (Url "pr"))
        map (.id) (spawnable [] twoTasks) `shouldBe` [t1]
        map (.id) . spawnable [] <$> reviewed `shouldBe` Right []
        map (.id) . spawnable [] <$> (reviewed >>= moved t1 (Merged (Url "pr"))) `shouldBe` Right [t2]

    it "awaits the merge of a dependency in review" $
        mergesAwaited <$> moved t1 (InReview (Url "pr")) twoTasks `shouldBe` Right [t1]

    it "leaves the fan-out with its tasks idle in review" $
        (applied [moved t1 (InReview (Url "pr"))] >>= leave) `shouldBe` Right ()

    it "spawns no task whose dependency is parked: it never merges" $
        map (.id) . spawnable [] <$> moved t1 (Parked "out of scope" Nothing) twoTasks `shouldBe` Right []

    it "counts the fan-out all parked only once every task is" $
        map (fmap allParked) [moved t1 (Parked "out of scope" Nothing) twoTasks, moved t1 (Parked "a" Nothing) twoTasks >>= moved t2 (Parked "b" Nothing)]
            `shouldBe` [Right False, Right True]

    describe "a new breakdown" $ do
        it "starts a fresh fan-out" $
            (spawned [] (childFor "c1" t1) independent >>= handedBack (runId "c1") (Finished (oneLine "PR")) >>= moved t1 (Merged (Url "pr")) >>= broken (tasksOf (plainTask "t3" [] :| [])))
                `shouldBe` Right (fresh (tasksOf (plainTask "t3" [] :| [])))

        it "is refused while an agent is at work" $
            (spawning [] t1 independent >>= spawned [] (childFor "c2" t2) >>= broken (tasksOf (plainTask "t3" [] :| [])))
                `shouldBe` Left (Busy (t1 :| [t2]))

    describe "breakdown" $ do
        it "refuses a task named twice" $
            breakdown (plainTask "t1" [] :| [plainTask "t1" []]) `shouldBe` Left (TaskTwice t1)

        it "refuses a dependency on a later task, so dependencies never cycle" $
            breakdown (plainTask "t1" ["t2"] :| [plainTask "t2" []]) `shouldBe` Left (DependsLater t1 t2)
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
childFor child taskId = Child (runId child) taskId "log" "worktree"

-- | A breakdown's fan-out: a first breakdown has no agent at work to refuse it.
fresh :: Tasks -> Fan
fresh tasks = either (error . show) id (broken tasks emptyFan)

-- | The task's PR merged.
merged :: Fan -> TaskId -> Bool
merged fan task = case Map.lookup task fan.moves of
    Just (Merged _) -> True
    Just (Parked _ _) -> False
    Just (InReview _) -> False
    Just (InCi _) -> False
    Nothing -> False

tshow :: Int -> Text.Text
tshow = Text.pack . show

-- | A breakdown, then spawns, hand-backs and moves, each kept only where the fan accepts it.
genFan :: Gen Fan
genFan = do
    tasks <- genTasks
    changes <- Gen.list (Range.linear 0 25) genChange
    pure (foldl' (\fan (n, change) -> fromRight fan (change n fan)) (fresh tasks) (zip [0 :: Int ..] changes))
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
            , (\i _ fan -> Right (triaged (pickChild i fan) fan)) <$> Gen.int (Range.linear 0 10)
            , (\i _ fan -> resumed (pickChild i fan) fan) <$> Gen.int (Range.linear 0 10)
            ]
    pickChild i fan = case fan.children of
        [] -> runId "none"
        children -> (children !! (i `mod` length children)).child.run
