{- | The 10x's fan-out as the fold sees it: the tasks of the breakdown, the
child run spawned for each, what each child said, and where each task's PR
stands. A task is settled when its latest child finished, or its PR is in
review, merged or parked; the fan-out leaves its state only once every task
is settled. Which tasks to spawn next is derived here too: at most @width@
children run at once, at most one of them heavy, and a task waits for its
dependencies to settle.
-}
module State.Fan (
    Fan (..),
    ChildRun (..),
    Refusal (..),
    emptyFan,
    broken,
    spawned,
    handedBack,
    moved,
    held,
    leave,
    running,
    latest,
    childrenOf,
    settled,
    unsettled,
    spawnable,
    tries,
) where

import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Numeric.Natural (Natural)
import State.Event ( Child (..), RunId, Tasks, Said (..), Task (..), TaskId, TaskState (..), Url, taskList)

data Fan = Fan
    { tasks :: [Task]
    -- ^ In the breakdown's order.
    , children :: [ChildRun]
    -- ^ Oldest first.
    , moves :: Map TaskId TaskState
    -- ^ The latest state recorded of each task.
    , held :: [(TaskId, Url)]
    -- ^ Oldest first.
    }
    deriving stock (Eq, Show)

-- | A child run and its hand-backs, oldest first.
data ChildRun = ChildRun {child :: Child, said :: [Said]}
    deriving stock (Eq, Show)

data Refusal
    = UnknownTask TaskId
    | -- | The task's child is still running: a second one is not spawned.
      StillRunning TaskId RunId
    | SpawnedTwice RunId
    | UnknownChild RunId
    | -- | The child finished or stopped: it hands back nothing more.
      ChildOver RunId
    | -- | The fan-out is not done while these tasks are not settled.
      Unsettled (NonEmpty TaskId)
    deriving stock (Eq, Show)

emptyFan :: Fan
emptyFan = Fan {tasks = [], children = [], moves = Map.empty, held = []}

broken :: Tasks -> Fan -> Fan
broken tasks fan = fan {tasks = taskList tasks}

spawned :: Child -> Fan -> Either Refusal Fan
spawned child fan = do
    _ <- known child.task fan
    case (find ((== child.run) . (.child.run)) fan.children, find ((== child.task) . (.child.task)) (running fan)) of
        (Just _, _) -> Left (SpawnedTwice child.run)
        (Nothing, Just other) -> Left (StillRunning child.task other.child.run)
        (Nothing, Nothing) -> Right fan {children = fan.children <> [ChildRun child []]}

handedBack :: RunId -> Said -> Fan -> Either Refusal Fan
handedBack run said fan = case find ((== run) . (.child.run)) fan.children of
    Nothing -> Left (UnknownChild run)
    Just found
        | live found -> Right fan {children = map add fan.children}
        | otherwise -> Left (ChildOver run)
  where
    add childRun
        | childRun.child.run == run = childRun {said = childRun.said <> [said]}
        | otherwise = childRun

moved :: TaskId -> TaskState -> Fan -> Either Refusal Fan
moved task state fan = (\_ -> fan {moves = Map.insert task state fan.moves}) <$> known task fan

held :: TaskId -> Url -> Fan -> Either Refusal Fan
held task url fan = (\_ -> fan {held = fan.held <> [(task, url)]}) <$> known task fan

-- | The fan-out may leave its state: every task is settled.
leave :: Fan -> Either Refusal ()
leave fan = maybe (Right ()) (Left . Unsettled) (NonEmpty.nonEmpty (unsettled fan))

known :: TaskId -> Fan -> Either Refusal Task
known task fan = maybe (Left (UnknownTask task)) Right (find ((== task) . (.id)) fan.tasks)

-- | The children not yet finished or stopped, oldest first.
running :: Fan -> [ChildRun]
running fan = filter live fan.children

-- | A child is over once it finished or stopped; asking up or awaiting CI, it runs on.
live :: ChildRun -> Bool
live childRun = case latest childRun of
    Nothing -> True
    Just said -> case said of
        Finished _ -> False
        AsksUp _ -> True
        AwaitsCi _ -> True
        Ended _ -> False

-- | What the child said last, 'Nothing' while it has not handed back.
latest :: ChildRun -> Maybe Said
latest childRun = case reverse childRun.said of
    said : _ -> Just said
    [] -> Nothing

-- | The task's children, oldest first.
childrenOf :: Fan -> TaskId -> [ChildRun]
childrenOf fan task = [childRun | childRun <- fan.children, childRun.child.task == task]

{- | Parked, or no child of it runs and its PR is in review or merged, or its
latest child finished. A stopped child leaves the task open: another child
may take it, or the 10x parks it. Parking settles even a child that never
handed back, so a lost child cannot keep the fan-out open.
-}
settled :: Fan -> TaskId -> Bool
settled fan task = case Map.lookup task fan.moves of
    Just (Parked _ _) -> True
    Just (InReview _) -> idle
    Just (Merged _) -> idle
    Just (InCi _) -> finished
    Nothing -> finished
  where
    children = childrenOf fan task
    idle = not (any live children)
    finished = case latest =<< listToMaybe (reverse children) of
        Just (Finished _) -> True
        Just (AsksUp _) -> False
        Just (AwaitsCi _) -> False
        Just (Ended _) -> False
        Nothing -> False

unsettled :: Fan -> [TaskId]
unsettled fan = [task.id | task <- fan.tasks, not (settled fan task.id)]

{- | The tasks to spawn now, in the breakdown's order: unsettled, no child
running, dependencies settled, within the free slots of @width@, and at most
one heavy task running at once.
-}
spawnable :: Natural -> Fan -> [Task]
spawnable width fan = pick (fromIntegral width - length busy) (any (.heavy) busy) ready
  where
    busy = [task | childRun <- running fan, task <- fan.tasks, task.id == childRun.child.task]
    ready =
        [ task
        | task <- fan.tasks
        , not (settled fan task.id)
        , task.id `notElem` map (.id) busy
        , all (settled fan) task.deps
        ]
    pick :: Int -> Bool -> [Task] -> [Task]
    pick slots heavyTaken = \case
        task : rest
            | slots <= 0 -> []
            | task.heavy && heavyTaken -> pick slots heavyTaken rest
            | otherwise -> task : pick (slots - 1) (heavyTaken || task.heavy) rest
        [] -> []

-- | The children spawned for the task so far.
tries :: Fan -> TaskId -> Int
tries fan task = length (childrenOf fan task)
