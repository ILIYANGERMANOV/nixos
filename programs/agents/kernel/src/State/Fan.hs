{- | The 10x's fan-out as the fold sees it: the tasks of the breakdown, the
child run spawned for each, what each child said, and where each task's PR
stands. A task is settled when its latest child finished, or its PR is in
review, merged or parked; the fan-out leaves its state only once every task
is settled. A task has an agent at work from the 10x's spawn or resume until
its child hands back, so the 10x sends one agent per task, once. A child's
stop is the 10x's to triage before another child takes the task. Which tasks
to spawn next is derived here too: at most @width@ tasks at work at once, at
most one of them heavy, and a task waits for its dependencies to settle.
-}
module State.Fan (
    Fan (..),
    ChildRun (..),
    Refusal (..),
    emptyFan,
    broken,
    spawning,
    spawned,
    resumed,
    triaged,
    handedBack,
    moved,
    held,
    leave,
    closed,
    unmerged,
    lookupTask,
    running,
    waiting,
    untriaged,
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
import Data.Set (Set)
import Data.Set qualified as Set
import Numeric.Natural (Natural)
import State.Event (Child (..), RunId, Said (..), Stop, Task (..), TaskId, TaskState (..), Tasks, Url, taskList)

data Fan = Fan
    { tasks :: [Task]
    -- ^ In the breakdown's order.
    , children :: [ChildRun]
    -- ^ Oldest first.
    , moves :: Map TaskId TaskState
    -- ^ The latest state recorded of each task.
    , held :: [(TaskId, Url)]
    -- ^ Oldest first.
    , atWork :: Set TaskId
    -- ^ The tasks with an agent at work: spawned or resumed, and not handed back since.
    }
    deriving stock (Eq, Show)

{- | A child run, its hand-backs, oldest first, and whether its stop was put
to the 10x as a question (@state ask --from@).
-}
data ChildRun = ChildRun {child :: Child, said :: [Said], triage :: Triage}
    deriving stock (Eq, Show)

-- | A stopped child's stop, until the 10x asks it as a question of its own.
data Triage = Untriaged | Triaged
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
    | -- | An agent works on the task already: one agent per task.
      AtWork TaskId
    | -- | The child stopped and its stop is not triaged yet: no retry before it.
      StopUntriaged RunId
    | -- | The run is not over while these tasks are neither merged nor parked.
      Unmerged (NonEmpty TaskId)
    deriving stock (Eq, Show)

emptyFan :: Fan
emptyFan = Fan {tasks = [], children = [], moves = Map.empty, held = [], atWork = Set.empty}

broken :: Tasks -> Fan -> Fan
broken tasks fan = fan {tasks = taskList tasks}

{- | The 10x sends an engineer to the task: refused while one works on it,
while a child of it runs on, or before its last child's stop is triaged.
-}
spawning :: TaskId -> Fan -> Either Refusal Fan
spawning task fan = do
    _ <- known task fan
    case (Set.member task fan.atWork, find ((== task) . (.child.task)) (running fan), find ((== task) . (.task) . fst) (untriaged fan)) of
        (True, _, _) -> Left (AtWork task)
        (False, Just other, _) -> Left (StillRunning task other.child.run)
        (False, Nothing, Just (stopped, _)) -> Left (StopUntriaged stopped.run)
        (False, Nothing, Nothing) -> Right fan {atWork = Set.insert task fan.atWork}

-- | The child's @init@: its task has an agent at work, spawned by the 10x or not.
spawned :: Child -> Fan -> Either Refusal Fan
spawned child fan = do
    _ <- known child.task fan
    case (find ((== child.run) . (.child.run)) fan.children, find ((== child.task) . (.child.task)) (running fan)) of
        (Just _, _) -> Left (SpawnedTwice child.run)
        (Nothing, Just other) -> Left (StillRunning child.task other.child.run)
        (Nothing, Nothing) -> Right fan {children = fan.children <> [ChildRun child [] Untriaged], atWork = Set.insert child.task fan.atWork}

-- | The 10x resumes a child that waits on it: refused while an agent works on its task.
resumed :: RunId -> Fan -> Either Refusal Fan
resumed run fan = case find ((== run) . (.child.run)) fan.children of
    Nothing -> Left (UnknownChild run)
    Just found
        | not (live found) -> Left (ChildOver run)
        | Set.member found.child.task fan.atWork -> Left (AtWork found.child.task)
        | otherwise -> Right fan {atWork = Set.insert found.child.task fan.atWork}

-- | A question the 10x asked from this child: after the child stopped, it triages the stop.
triaged :: RunId -> Fan -> Fan
triaged run fan = fan {children = map mark fan.children}
  where
    mark childRun = case latest childRun of
        Just (Ended _) | childRun.child.run == run -> childRun {triage = Triaged}
        _ -> childRun

-- | A child's hand-back: its task has no agent at work until the 10x sends one.
handedBack :: RunId -> Said -> Fan -> Either Refusal Fan
handedBack run said fan = case find ((== run) . (.child.run)) fan.children of
    Nothing -> Left (UnknownChild run)
    Just found
        | live found -> Right fan {children = map add fan.children, atWork = Set.delete found.child.task fan.atWork}
        | otherwise -> Left (ChildOver run)
  where
    add childRun
        | childRun.child.run == run = childRun {said = childRun.said <> [said]}
        | otherwise = childRun

moved :: TaskId -> TaskState -> Fan -> Either Refusal Fan
moved task state fan = fan {moves = Map.insert task state fan.moves} <$ known task fan

held :: TaskId -> Url -> Fan -> Either Refusal Fan
held task url fan = fan {held = fan.held <> [(task, url)]} <$ known task fan

-- | The fan-out may leave its state: every task is settled.
leave :: Fan -> Either Refusal ()
leave fan = maybe (Right ()) (Left . Unsettled) (NonEmpty.nonEmpty (unsettled fan))

-- | The run may end: every task is merged or parked.
closed :: Fan -> Either Refusal ()
closed fan = maybe (Right ()) (Left . Unmerged) (NonEmpty.nonEmpty (unmerged fan))

-- | The tasks neither merged nor parked, in the breakdown's order.
unmerged :: Fan -> [TaskId]
unmerged fan = [task.id | task <- fan.tasks, not (over task.id)]
  where
    over task = case Map.lookup task fan.moves of
        Just (Merged _) -> True
        Just (Parked _ _) -> True
        Just (InReview _) -> False
        Just (InCi _) -> False
        Nothing -> False

known :: TaskId -> Fan -> Either Refusal Task
known task fan = maybe (Left (UnknownTask task)) Right (lookupTask fan task)

-- | The breakdown's task of this id.
lookupTask :: Fan -> TaskId -> Maybe Task
lookupTask fan task = find ((== task) . (.id)) fan.tasks

-- | The children not yet finished or stopped, oldest first.
running :: Fan -> [ChildRun]
running fan = filter live fan.children

-- | The running children no agent works for: each waits on the 10x.
waiting :: Fan -> [ChildRun]
waiting fan = [childRun | childRun <- running fan, Set.notMember childRun.child.task fan.atWork]

-- | The stopped children whose stop the 10x has yet to triage, oldest first: each its task's latest child.
untriaged :: Fan -> [(Child, Stop)]
untriaged fan =
    [ (childRun.child, stop)
    | task <- fan.tasks
    , not (settled fan task.id)
    , childRun : _ <- [reverse (childrenOf fan task.id)]
    , Untriaged <- [childRun.triage]
    , Just (Ended stop) <- [latest childRun]
    ]

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
running and no agent at work, its last stop triaged, dependencies settled,
within the free slots of @width@, and at most one heavy task busy at once.
-}
spawnable :: Natural -> Fan -> [Task]
spawnable width fan = pick (fromIntegral width - length busy) (any (.heavy) busy) ready
  where
    busy = [task | task <- fan.tasks, Set.member task.id fan.atWork || task.id `elem` map (.child.task) (running fan)]
    ready =
        [ task
        | task <- fan.tasks
        , not (settled fan task.id)
        , task.id `notElem` map (.id) busy
        , task.id `notElem` map ((.task) . fst) (untriaged fan)
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
