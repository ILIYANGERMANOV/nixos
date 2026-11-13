module State.FanSpec (spec) where

import Data.Either (fromRight, isRight)
import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (Gen, assert, cover, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Event
import State.EventGen (genSaid, genTaskId, genTaskState, genTasks, oneLine, runId, tasksOf)
import State.Fan
import State.Mode (Quality (..), Size (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Fan" $ do
    it "spawnable_respects_slots_heavy_and_deps" . hedgehog $ do
        fan <- forAll genFan
        width <- forAll (Gen.integral (Range.linear 1 4))
        let picks = spawnable width fan
            busy = [task | childRun <- running fan, task <- fan.tasks, task.id == childRun.child.task]
        cover 10 "spawns some" (not (null picks))
        cover 5 "a heavy task waits" (any (.heavy) busy && any (.heavy) [task | task <- fan.tasks, task.id `elem` unsettled fan])
        assert (length picks <= max 0 (fromIntegral width - length busy))
        assert (length (filter (.heavy) (picks <> busy)) <= max 1 (length (filter (.heavy) busy)))
        for_ picks $ \task -> do
            assert (not (settled fan task.id))
            assert (task.id `notElem` map (.id) busy)
            assert (all (settled fan) task.deps)

    it "spawning_every_spawnable_task_leaves_none_to_spawn" . hedgehog $ do
        fan <- forAll genFan
        width <- forAll (Gen.integral (Range.linear 1 4))
        let spawnedAll = foldl' (\current (n, task) -> fromRight current (spawned (childFor ("new" <> tshow n) task.id) current)) fan (zip [0 :: Int ..] (spawnable width fan))
        spawnable width spawnedAll === []

    it "leaves_only_when_every_task_is_settled" . hedgehog $ do
        fan <- forAll genFan
        cover 10 "settled" (null (unsettled fan))
        isRight (leave fan) === all (settled fan . (.id)) fan.tasks

    it "settles a task whose child finished" $
        settledAfter [spawned (childFor "c1" t1), handedBack (runId "c1") (Finished (oneLine "PR #1"))] `shouldBe` Right True

    it "leaves a task open after its child stops, to spawn again, and counts both tries" $ do
        let fan = applied [spawned (childFor "c1" t1), handedBack (runId "c1") (Ended (Stop Blocked "no access"))]
        map (.id) . spawnable 3 <$> fan `shouldBe` Right [t1]
        (\f -> tries f t1) <$> (fan >>= spawned (childFor "c2" t1)) `shouldBe` Right 2

    it "keeps a child running while it asks up or awaits CI" $
        length . running <$> applied [spawned (childFor "c1" t1), handedBack (runId "c1") (AwaitsCi (oneLine "PR #1"))] `shouldBe` Right 1

    it "settles a parked task, so the fan-out may leave" $
        (applied [moved t1 (Parked "out of scope" Nothing)] >>= leave) `shouldBe` Right ()

    it "does not settle a task whose PR is in CI" $
        (applied [moved t1 (InCi (Url "pr"))] >>= leave) `shouldBe` Left (Unsettled (t1 :| []))

    it "refuses a second child for a task whose child runs" $
        applied [spawned (childFor "c1" t1), spawned (childFor "c2" t1)] `shouldBe` Left (StillRunning t1 (runId "c1"))

    it "refuses a hand-back from a child that finished" $
        applied [spawned (childFor "c1" t1), handedBack (runId "c1") (Finished (oneLine "PR")), handedBack (runId "c1") (Finished (oneLine "PR"))]
            `shouldBe` Left (ChildOver (runId "c1"))

    it "refuses a hand-back from a child never spawned" $
        applied [handedBack (runId "c9") (Finished (oneLine "PR"))] `shouldBe` Left (UnknownChild (runId "c9"))

    it "refuses a task the breakdown lacks" $
        applied [held (TaskId "t9") (Url "u")] `shouldBe` Left (UnknownTask (TaskId "t9"))

    it "spawns a task only once its dependency settled" $ do
        let two = broken (tasksOf (taskOf t1 [] :| [taskOf t2 [t1]])) emptyFan
        map (.id) (spawnable 3 two) `shouldBe` [t1]
        map (.id) <$> (spawnable 3 <$> (spawned (childFor "c1" t1) two >>= handedBack (runId "c1") (Finished (oneLine "PR")))) `shouldBe` Right [t2]

    it "runs one heavy task at a time" $
        map (.id) (spawnable 3 (broken (tasksOf ((taskOf t1 []) {heavy = True} :| [(taskOf t2 []) {heavy = True}])) emptyFan)) `shouldBe` [t1]

    describe "breakdown" $ do
        it "refuses a task named twice" $
            breakdown (taskOf t1 [] :| [taskOf t1 []]) `shouldBe` Left (TaskTwice t1)

        it "refuses a dependency on a later task, so dependencies never cycle" $
            breakdown (taskOf t1 [t2] :| [taskOf t2 []]) `shouldSatisfy` (== Left (DependsLater t1 t2))
  where
    settledAfter changes = (`settled` t1) <$> applied changes
    applied = foldl' (>>=) (Right oneTask)
    oneTask = broken (tasksOf (taskOf t1 [] :| [])) emptyFan

t1, t2 :: TaskId
t1 = TaskId "t1"
t2 = TaskId "t2"

taskOf :: TaskId -> [TaskId] -> Task
taskOf taskId deps = Task taskId deps (Branch "main") (Branch "b") Balanced Normal False False Set.empty

childFor :: Text.Text -> TaskId -> Child
childFor child taskId = Child (runId child) taskId "log" "worktree"

tshow :: Int -> Text.Text
tshow = Text.pack . show

-- | A breakdown, then spawns, hand-backs and moves, each kept only where the fan accepts it.
genFan :: Gen Fan
genFan = do
    tasks <- genTasks
    changes <- Gen.list (Range.linear 0 25) genChange
    pure (foldl' (\fan (n, change) -> fromRight fan (change n fan)) (broken tasks emptyFan) (zip [0 :: Int ..] changes))
  where
    genChange =
        Gen.choice
            [ (\taskId n -> spawned (childFor ("c" <> tshow n) taskId)) <$> genTaskId
            , (\i said _ fan -> case fan.children of
                [] -> Right fan
                children -> handedBack (children !! (i `mod` length children)).child.run said fan)
                <$> Gen.int (Range.linear 0 10)
                <*> genSaid
            , (\taskId state _ -> moved taskId state) <$> genTaskId <*> genTaskState
            ]
