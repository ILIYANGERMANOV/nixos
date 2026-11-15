{- | The 10x's fan-out as the fold sees it: the tasks of the breakdown, the
child run spawned for each, what each child said, and where each task's PR
stands. A task is settled when its latest child finished, or its PR is in
review, merged or parked; the fan-out leaves its state only once every task
is settled. A task has an agent at work from the 10x's spawn or resume until
its child hands back or the task is parked, so the 10x sends one agent per
task, once. A child's stop is the 10x's to triage before another child takes
the task. Which tasks to spawn next is derived here too: every task free of
an agent, once its dependencies merged. A new breakdown starts a fresh
fan-out, refused while an agent is at work on the old one.
-}
module State.Run.Fan (
    Fan (..),
    ChildRun (..),
    Heard (..),
    Refusal (..),
    emptyFan,
    broken,
    added,
    restarted,
    spawning,
    spawned,
    resumed,
    triaged,
    handedBack,
    moved,
    held,
    actedOn,
    leave,
    closed,
    unmerged,
    allParked,
    lookupTask,
    childTask,
    running,
    waiting,
    untriaged,
    latest,
    childrenOf,
    settled,
    unsettled,
    unrecorded,
    spawnable,
    mergesAwaited,
    tries,
) where

import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import State.Run.Event (Child (..), RunId, Said (..), Stop, Task (..), TaskId, TaskState (..), Tasks, Url, taskList)

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

-- | A child run and its hand-backs, oldest first.
data ChildRun = ChildRun {child :: Child, said :: [Heard]}
    deriving stock (Eq, Show)

{- | A hand-back as the fan-out keeps it: a stop, once the 10x put it as a
question of its own (@state ask --from@), is triaged.
-}
data Heard = Heard Said | TriagedStop Stop
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
    | -- | The child's question is open with the user: no retry before its answer.
      AwaitsUser RunId
    | -- | A new breakdown while these tasks have an agent at work: it would orphan them.
      Busy (NonEmpty TaskId)
    | -- | The run is not over while these tasks are neither merged nor parked.
      Unmerged (NonEmpty TaskId)
    | -- | A task added under an id the fan-out has already.
      TaskExists TaskId
    deriving stock (Eq, Show)

emptyFan :: Fan
emptyFan = Fan {tasks = [], children = [], moves = Map.empty, held = [], atWork = Set.empty}

-- | A breakdown starts a fresh fan-out: refused while an agent works on a task of the old one.
broken :: Tasks -> Fan -> Either Refusal Fan
broken tasks fan = case NonEmpty.nonEmpty (map (.id) (busy fan)) of
    Just working -> Left (Busy working)
    Nothing -> Right emptyFan {tasks = taskList tasks}

{- | A task joins after the breakdown, last: its dependencies are tasks the
fan-out has, so they stay acyclic. It is spawnable as any task is.
-}
added :: Task -> Fan -> Either Refusal Fan
added task fan = case (lookupTask fan task.id, filter (isNothing . lookupTask fan) task.deps) of
    (Just _, _) -> Left (TaskExists task.id)
    (Nothing, unknown : _) -> Left (UnknownTask unknown)
    (Nothing, []) -> Right fan {tasks = fan.tasks <> [task]}

-- | Every agent at work died with the lead's session: their children wait on the 10x.
restarted :: Fan -> Fan
restarted fan = fan {atWork = Set.empty}

{- | The 10x sends an engineer to the task: refused while one works on it, or
as 'free' refuses. @asking@ is the children whose question is still open.
-}
spawning :: [RunId] -> TaskId -> Fan -> Either Refusal Fan
spawning asking task fan = do
    found <- known task fan
    case Set.member task fan.atWork of
        True -> Left (AtWork task)
        False -> free asking found fan
    Right fan {atWork = Set.insert task fan.atWork}

-- | The child's @init@: its task has an agent at work, spawned by the 10x or not.
spawned :: [RunId] -> Child -> Fan -> Either Refusal Fan
spawned asking child fan = do
    found <- known child.task fan
    case find ((== child.run) . (.child.run)) fan.children of
        Just _ -> Left (SpawnedTwice child.run)
        Nothing -> free asking found fan
    Right fan {children = fan.children <> [ChildRun child []], atWork = Set.insert child.task fan.atWork}

{- | A new child may take the task: no child of it runs on, its last child's
stop is triaged, and no question of its children is open (@asking@).
-}
free :: [RunId] -> Task -> Fan -> Either Refusal ()
free asking task fan = case (find ((== task.id) . (.child.task)) (running fan), find ((== task.id) . (.task) . fst) (untriaged fan), askingUp) of
    (Just other, _, _) -> Left (StillRunning task.id other.child.run)
    (Nothing, Just (stopped, _), _) -> Left (StopUntriaged stopped.run)
    (Nothing, Nothing, Just run) -> Left (AwaitsUser run)
    (Nothing, Nothing, Nothing) -> Right ()
  where
    askingUp = find (`elem` asking) (map (.child.run) (childrenOf fan task.id))

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
    mark childRun = case reverse childRun.said of
        Heard (Ended stop) : before | childRun.child.run == run -> childRun {said = reverse (TriagedStop stop : before)}
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
        | childRun.child.run == run = childRun {said = childRun.said <> [Heard said]}
        | otherwise = childRun

-- | A parked task has no agent at work: parking settles even a lost child.
moved :: TaskId -> TaskState -> Fan -> Either Refusal Fan
moved task state fan = fan {moves = Map.insert task state fan.moves, atWork = working} <$ known task fan
  where
    working = case state of
        Parked _ _ -> Set.delete task fan.atWork
        InCi _ -> fan.atWork
        InReview _ -> fan.atWork
        Merged _ -> fan.atWork

held :: TaskId -> Url -> Fan -> Either Refusal Fan
held task url fan = fan {held = fan.held <> [(task, url)]} <$ known task fan

-- | A wake acted on is held no more; one acted on already stays so.
actedOn :: TaskId -> Url -> Fan -> Either Refusal Fan
actedOn task url fan = fan {held = filter (/= (task, url)) fan.held} <$ known task fan

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

-- | The breakdown has tasks and every one is parked: nothing will merge.
allParked :: Fan -> Bool
allParked fan = not (null fan.tasks) && all (parked . (.id)) fan.tasks
  where
    parked task = case Map.lookup task fan.moves of
        Just (Parked _ _) -> True
        Just (Merged _) -> False
        Just (InReview _) -> False
        Just (InCi _) -> False
        Nothing -> False

known :: TaskId -> Fan -> Either Refusal Task
known task fan = maybe (Left (UnknownTask task)) Right (lookupTask fan task)

-- | The breakdown's task of this id.
lookupTask :: Fan -> TaskId -> Maybe Task
lookupTask fan task = find ((== task) . (.id)) fan.tasks

-- | The breakdown's task the child of this run id took.
childTask :: Fan -> RunId -> Maybe Task
childTask fan run = lookupTask fan . (.child.task) =<< find ((== run) . (.child.run)) fan.children

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
    , Heard (Ended stop) : _ <- [reverse childRun.said]
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

-- | What the child said last, triaged or not; 'Nothing' while it has not handed back.
latest :: ChildRun -> Maybe Said
latest childRun = case reverse childRun.said of
    Heard said : _ -> Just said
    TriagedStop stop : _ -> Just (Ended stop)
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
    Just (InCi _) -> finished fan task
    Nothing -> finished fan task
  where
    idle = not (any live (childrenOf fan task))

-- | The task's latest child finished.
finished :: Fan -> TaskId -> Bool
finished fan task = case latest =<< listToMaybe (reverse (childrenOf fan task)) of
    Just (Finished _) -> True
    Just (AsksUp _) -> False
    Just (AwaitsCi _) -> False
    Just (Ended _) -> False
    Nothing -> False

-- | The task's latest child finished and no state of its PR is recorded: the 10x records it.
unrecorded :: Fan -> TaskId -> Bool
unrecorded fan task = finished fan task && Map.notMember task fan.moves

unsettled :: Fan -> [TaskId]
unsettled fan = [task.id | task <- fan.tasks, not (settled fan task.id)]

{- | The tasks to spawn now, in the breakdown's order: unsettled, no child
running and no agent at work, its last stop triaged, no question of its
children open (@asking@), and every dependency merged. No cap: how many run
at once is the 10x's call, made by the dependencies it draws.
-}
spawnable :: [RunId] -> Fan -> [Task]
spawnable asking fan =
    [ task
    | task <- fan.tasks
    , not (settled fan task.id)
    , task.id `notElem` map (.id) (busy fan)
    , task.id `notElem` map ((.task) . fst) (untriaged fan)
    , all ((`notElem` asking) . (.child.run)) (childrenOf fan task.id)
    , all (built fan) task.deps
    ]

{- | Merged: a dependent starts from the base the dependency merged into, as
GitHub Actions' @needs@ waits for success. A dependency in review or parked
keeps its dependents waiting; 'settled' still lets the fan-out leave then.
-}
built :: Fan -> TaskId -> Bool
built fan task = case Map.lookup task fan.moves of
    Just (Merged _) -> True
    Just (Parked _ _) -> False
    Just (InCi _) -> False
    Just (InReview _) -> False
    Nothing -> False

{- | The PRs in review or CI an unsettled task depends on, in the
breakdown's order: the fan-out waits for them to merge.
-}
mergesAwaited :: Fan -> [TaskId]
mergesAwaited fan = [dep.id | dep <- fan.tasks, opened dep.id, any (elem dep.id . (.deps)) open]
  where
    open = [task | task <- fan.tasks, not (settled fan task.id)]
    opened task = case Map.lookup task fan.moves of
        Just (InReview _) -> True
        Just (InCi _) -> True
        Just (Merged _) -> False
        Just (Parked _ _) -> False
        Nothing -> False

-- | The tasks with an agent at work or a child running, in the breakdown's order.
busy :: Fan -> [Task]
busy fan = [task | task <- fan.tasks, Set.member task.id fan.atWork || task.id `elem` map (.child.task) (running fan)]

-- | The children spawned for the task so far.
tries :: Fan -> TaskId -> Int
tries fan task = length (childrenOf fan task)
