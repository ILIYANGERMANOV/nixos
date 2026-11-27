{- | The 10x's fan-out as the fold sees it: the tasks of the breakdown, the
child run spawned for each, what each child said, and where each task's PR
stands. A task is settled when its latest child finished and no PR state is
recorded, or its PR is in review, merged, kept, delivered or parked; a PR in CI is not, as a
fixer may be at work on it. The fan-out leaves its state only once every task
is settled. A task has an agent at work from the 10x's spawn or resume until
its child hands back or the task is parked, so the 10x sends one agent per
task, once. A child's stop is the 10x's to triage before another child takes
the task. Which tasks to spawn next is derived here too: every task free of
an agent, once its dependencies merged. A new breakdown starts a fresh
fan-out, refused while an agent is at work on the old one.
-}
module State.Run.Fan (
    Fan (..),
    Breakdown (..),
    tasksOf,
    taskRef,
    childRef,
    childTaskId,
    ChildRun (..),
    Heard (..),
    Refusal (..),
    emptyFan,
    broken,
    added,
    rebased,
    headed,
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
    merged,
    allParked,
    lookupTask,
    childTask,
    running,
    waiting,
    untriaged,
    latest,
    askedBy,
    pullRequest,
    childrenOf,
    settled,
    unsettled,
    unrecorded,
    spawnable,
    mergesAwaited,
    ciAwaited,
    tries,
    retryLeft,
) where

import Data.Foldable (toList)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Numeric.Natural (Natural)
import State.Run.Ask (QId)
import State.Run.Event (
    Base,
    Child (..),
    ChildTask (..),
    RunId,
    Said (..),
    Sha,
    Shape (..),
    Stop,
    Task (..),
    TaskId,
    TaskRef (TaskRef, task),
    TaskState (..),
    Tasks,
    Url,
    builtOn,
    tasksInOrder,
 )

data Fan = Fan
    { breakdown :: Maybe Breakdown
    -- ^ None before the fan-out's first breakdown or added task.
    , children :: [ChildRun]
    -- ^ Oldest first.
    , moves :: Map TaskId TaskState
    -- ^ The latest state recorded of each task.
    , held :: [(TaskId, Url)]
    -- ^ Oldest first.
    , atWork :: Set TaskId
    -- ^ The tasks with an agent at work: spawned or resumed, and not handed back since.
    , rounds :: Map TaskId Int
    -- ^ The rounds asked of each task on its PR: a task never asked one is absent.
    , heads :: Map TaskId Sha
    -- ^ The commit each task's branch was last seen at: a task never seen is absent.
    }
    deriving stock (Eq, Show)

{- | The fan-out's tasks, in the breakdown's order, and the seq of the
@breakdown.done@ that listed them, or of the @task_added@ that started them
when no breakdown did: each task's event names it beside the task.
-}
data Breakdown = Breakdown {seq :: Natural, tasks :: NonEmpty Task}
    deriving stock (Eq, Show)

-- | The breakdown's tasks, in its order: none before it.
tasksOf :: Fan -> [Task]
tasksOf fan = foldMap (NonEmpty.toList . (.tasks)) fan.breakdown

-- | The task of this id, by its identity: the fan-out's breakdown names it.
taskRef :: Fan -> TaskId -> Either Refusal TaskRef
taskRef fan task = case fan.breakdown of
    Just listed | any ((== task) . (.id)) listed.tasks -> Right (TaskRef task listed.seq)
    _ -> Left (UnknownTask task)

-- | The task the child of this run id took, as its @spawned@ names it: none for an untasked or unknown child.
childRef :: Fan -> RunId -> Maybe TaskRef
childRef fan run =
    find ((== run) . (.child.run)) fan.children >>= \found -> case found.child.task of
        Tasked ref -> Just ref
        Untasked -> Nothing

-- | What the child took, by the task's id alone.
childTaskId :: Child -> ChildTask TaskId
childTaskId child = (.task) <$> child.task

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
    | -- | The round is not over while these tasks are neither merged, kept, delivered nor parked.
      Unmerged (NonEmpty TaskId)
    | -- | Only a round on an existing PR is kept: any other PR is merged or parked.
      NotARound TaskId
    | -- | A round keeps its own PR only: this is that PR's URL.
      NotItsRound TaskId Url
    | -- | A task added under an id the fan-out has already.
      TaskExists TaskId
    | -- | The task's new base names this task, which is not an earlier one of the breakdown.
      BaseNotEarlier TaskId TaskId
    deriving stock (Eq, Show)

emptyFan :: Fan
emptyFan =
    Fan
        { breakdown = Nothing
        , children = []
        , moves = Map.empty
        , held = []
        , atWork = Set.empty
        , rounds = Map.empty
        , heads = Map.empty
        }

{- | A breakdown, logged at this seq, starts a fresh fan-out: refused while
an agent works on a task of the old one.
-}
broken :: Natural -> Tasks -> Fan -> Either Refusal Fan
broken n tasks fan = case NonEmpty.nonEmpty (map (.id) (busy fan)) of
    Just working -> Left (Busy working)
    Nothing -> Right emptyFan {breakdown = Just (Breakdown n (tasksInOrder tasks))}

{- | A task joins after the breakdown, last: its dependencies and its base's
task are tasks the fan-out has, so they stay acyclic. It is spawnable as any
task is. With no breakdown yet, it starts one at its own seq, @n@.
-}
added :: Natural -> Task -> Fan -> Either Refusal Fan
added n task fan = case ( lookupTask fan task.id
                        , filter (isNothing . lookupTask fan) (task.deps <> toList (builtOn task.base))
                        , fan.breakdown
                        ) of
    (Just _, _, _) -> Left (TaskExists task.id)
    (Nothing, unknown : _, _) -> Left (UnknownTask unknown)
    (Nothing, [], Just listed) -> Right fan {breakdown = Just listed {tasks = listed.tasks <> pure task}}
    (Nothing, [], Nothing) -> Right fan {breakdown = Just (Breakdown n (pure task))}

{- | The task builds on another base from here on. A task base names an
earlier task of the breakdown, as the breakdown's own bases do, so the
bases stay acyclic.
-}
rebased :: TaskId -> Base -> Fan -> Either Refusal Fan
rebased task base fan = do
    _ <- known task fan
    case builtOn base of
        Just on
            | on `notElem` earlier -> Left (BaseNotEarlier task on)
        Just _ -> Right ()
        Nothing -> Right ()
    Right fan {breakdown = (\listed -> listed {tasks = based <$> listed.tasks}) <$> fan.breakdown}
  where
    earlier = map (.id) (takeWhile ((/= task) . (.id)) (tasksOf fan))
    based found
        | found.id == task = found {base}
        | otherwise = found

-- | The commit the task's branch is at now.
headed :: TaskId -> Sha -> Fan -> Either Refusal Fan
headed task sha fan = fan {heads = Map.insert task sha fan.heads} <$ known task fan

-- | Every agent at work died with the lead's session: their children wait on the 10x.
restarted :: Fan -> Fan
restarted fan = fan {atWork = Set.empty}

{- | The 10x sends an engineer to the task: refused while one works on it, or
as 'free' refuses. @asking@ is the children whose question is still open.
A parked task sent one runs again.
-}
spawning :: [RunId] -> TaskId -> Fan -> Either Refusal Fan
spawning asking task fan = do
    found <- known task fan
    case Set.member task fan.atWork of
        True -> Left (AtWork task)
        False -> free asking found fan
    Right fan {atWork = Set.insert task fan.atWork, moves = unparked task fan.moves}

{- | The child's @init@: its task has an agent at work, spawned by the 10x or
not, and runs again if it was parked. An untasked child takes none: it runs
until it finishes or stops.
-}
spawned :: [RunId] -> Child -> Fan -> Either Refusal Fan
spawned asking child fan = case child.task of
    Tasked ref -> do
        found <- known ref.task fan
        new
        free asking found fan
        Right
            joined
                { atWork = Set.insert ref.task fan.atWork
                , moves = unparked ref.task fan.moves
                }
    Untasked -> joined <$ new
  where
    new = case find ((== child.run) . (.child.run)) fan.children of
        Just _ -> Left (SpawnedTwice child.run)
        Nothing -> Right ()
    joined = fan {children = fan.children <> [ChildRun child []]}

{- | A new child may take the task: no child of it runs on, its last child's
stop is triaged, and no question of its children is open (@asking@).
-}
free :: [RunId] -> Task -> Fan -> Either Refusal ()
free asking task fan = case ( runningOn task.id fan
                            , find ((== Tasked task.id) . childTaskId . fst) (untriaged fan)
                            , askingUp
                            ) of
    (Just other, _, _) -> Left (StillRunning task.id other.child.run)
    (Nothing, Just (stopped, _), _) -> Left (StopUntriaged stopped.run)
    (Nothing, Nothing, Just run) -> Left (AwaitsUser run)
    (Nothing, Nothing, Nothing) -> Right ()
  where
    askingUp = find (`elem` asking) (map (.child.run) (childrenOf fan task.id))

{- | A parked task an agent takes again is parked no more: with no state
recorded, it runs while its agent or child does. Any other state stays.
-}
unparked :: TaskId -> Map TaskId TaskState -> Map TaskId TaskState
unparked = Map.update $ \state -> case state of
    Parked _ _ -> Nothing
    InCi _ -> Just state
    InReview _ -> Just state
    Merged _ -> Just state
    Kept _ -> Just state
    Round _ -> Just state
    Delivered _ -> Just state

-- | The 10x resumes a child that waits on it: refused while an agent works on its task.
resumed :: RunId -> Fan -> Either Refusal Fan
resumed run fan = case find ((== run) . (.child.run)) fan.children of
    Nothing -> Left (UnknownChild run)
    Just found
        | not (live found) -> Left (ChildOver run)
        | otherwise -> case found.child.task of
            Tasked ref
                | Set.member ref.task fan.atWork -> Left (AtWork ref.task)
                | otherwise -> Right fan {atWork = Set.insert ref.task fan.atWork}
            Untasked -> Right fan

-- | A question the 10x asked from this child: after the child stopped, it triages the stop.
triaged :: RunId -> Fan -> Fan
triaged run fan = fan {children = map mark fan.children}
  where
    mark childRun = case reverse childRun.said of
        Heard (Ended stop) : before
            | childRun.child.run == run ->
                childRun {said = reverse (TriagedStop stop : before)}
        _ -> childRun

-- | A child's hand-back: its task has no agent at work until the 10x sends one.
handedBack :: RunId -> Said -> Fan -> Either Refusal Fan
handedBack run said fan = case find ((== run) . (.child.run)) fan.children of
    Nothing -> Left (UnknownChild run)
    Just found
        | live found ->
            Right fan {children = map add fan.children, atWork = idle found.child.task}
        | otherwise -> Left (ChildOver run)
  where
    add childRun
        | childRun.child.run == run = childRun {said = childRun.said <> [Heard said]}
        | otherwise = childRun
    idle = \case
        Tasked ref -> Set.delete ref.task fan.atWork
        Untasked -> fan.atWork

{- | A parked task has no agent at work: parking settles even a lost child.
Only a round's PR is kept, and only under that PR's own URL. A round makes
the task a round on its PR, refused while a child or an agent works on it.
A merged task stays merged: a later move, such as a stale review's, is
ignored, never refused, so a log holding one still replays.
-}
moved :: TaskId -> TaskState -> Fan -> Either Refusal Fan
moved task state fan = case Map.lookup task fan.moves of
    Just (Merged _) -> Right fan
    Just (Kept _) -> moving
    Just (Parked _ _) -> moving
    Just (Round _) -> moving
    Just (InReview _) -> moving
    Just (InCi _) -> moving
    Just (Delivered _) -> moving
    Nothing -> moving
  where
    moving = do
        found <- known task fan
        case (state, found.shape) of
            (Kept _, OwnPr) -> Left (NotARound task)
            (Kept kept, RoundOn roundPr)
                | kept == roundPr -> Right ()
                | otherwise -> Left (NotItsRound task roundPr)
            (Round _, _) -> idle
            (Parked _ _, _) -> Right ()
            (InCi _, _) -> Right ()
            (InReview _, _) -> Right ()
            (Merged _, _) -> Right ()
            (Delivered _, _) -> Right ()
        Right (rounded fan {moves = Map.insert task state fan.moves, atWork = working})
    idle = case (runningOn task fan, Set.member task fan.atWork) of
        (Just child, _) -> Left (StillRunning task child.child.run)
        (Nothing, True) -> Left (AtWork task)
        (Nothing, False) -> Right ()
    working = case state of
        Parked _ _ -> Set.delete task fan.atWork
        InCi _ -> fan.atWork
        InReview _ -> fan.atWork
        Merged _ -> fan.atWork
        Kept _ -> fan.atWork
        Round _ -> fan.atWork
        Delivered _ -> fan.atWork
    rounded after = case state of
        Round url ->
            after
                { breakdown =
                    (\listed -> listed {tasks = onRound url <$> listed.tasks}) <$> after.breakdown
                , rounds = Map.insertWith (+) task 1 after.rounds
                }
        Parked _ _ -> after
        InCi _ -> after
        InReview _ -> after
        Merged _ -> after
        Kept _ -> after
        Delivered _ -> after
    onRound url found
        | found.id == task = found {shape = RoundOn url}
        | otherwise = found

held :: TaskId -> Url -> Fan -> Either Refusal Fan
held task url fan = fan {held = fan.held <> [(task, url)]} <$ known task fan

-- | A wake acted on is held no more; one acted on already stays so.
actedOn :: TaskId -> Url -> Fan -> Either Refusal Fan
actedOn task url fan = fan {held = filter (/= (task, url)) fan.held} <$ known task fan

-- | The fan-out may leave its state: every task is settled.
leave :: Fan -> Either Refusal ()
leave fan = maybe (Right ()) (Left . Unsettled) (NonEmpty.nonEmpty (unsettled fan))

-- | The round may end: every task is merged, kept, delivered or parked.
closed :: Fan -> Either Refusal ()
closed fan = maybe (Right ()) (Left . Unmerged) (NonEmpty.nonEmpty (unmerged fan))

-- | The tasks neither merged, kept, delivered nor parked, in the breakdown's order.
unmerged :: Fan -> [TaskId]
unmerged fan = [task.id | task <- tasksOf fan, not (over task.id)]
  where
    over task = case Map.lookup task fan.moves of
        Just (Merged _) -> True
        Just (Kept _) -> True
        Just (Parked _ _) -> True
        Just (Delivered _) -> True
        Just (Round _) -> False
        Just (InReview _) -> False
        Just (InCi _) -> False
        Nothing -> False

-- | The breakdown has tasks and every one is parked: nothing will merge.
allParked :: Fan -> Bool
allParked fan = not (null (tasksOf fan)) && all (parked . (.id)) (tasksOf fan)
  where
    parked task = case Map.lookup task fan.moves of
        Just (Parked _ _) -> True
        Just (Merged _) -> False
        Just (Kept _) -> False
        Just (Round _) -> False
        Just (InReview _) -> False
        Just (InCi _) -> False
        Just (Delivered _) -> False
        Nothing -> False

known :: TaskId -> Fan -> Either Refusal Task
known task fan = maybe (Left (UnknownTask task)) Right (lookupTask fan task)

-- | The breakdown's task of this id.
lookupTask :: Fan -> TaskId -> Maybe Task
lookupTask fan task = find ((== task) . (.id)) (tasksOf fan)

-- | The breakdown's task the child of this run id took.
childTask :: Fan -> RunId -> Maybe Task
childTask fan run =
    find ((== run) . (.child.run)) fan.children >>= \found -> case found.child.task of
        Tasked ref -> lookupTask fan ref.task
        Untasked -> Nothing

-- | The children not yet finished or stopped, oldest first.
running :: Fan -> [ChildRun]
running fan = filter live fan.children

-- | The task's running child, if one runs.
runningOn :: TaskId -> Fan -> Maybe ChildRun
runningOn task fan = find ((== Tasked task) . childTaskId . (.child)) (running fan)

-- | The running children no agent works for: each waits on the 10x.
waiting :: Fan -> [ChildRun]
waiting fan =
    [ childRun
    | childRun <- running fan
    , Tasked ref <- [childRun.child.task]
    , Set.notMember ref.task fan.atWork
    ]

-- | The stopped children whose stop the 10x has yet to triage, oldest first: each its task's latest child.
untriaged :: Fan -> [(Child, Stop)]
untriaged fan =
    [ (childRun.child, stop)
    | task <- tasksOf fan
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
        Awaits _ _ -> True
        Ended _ -> False

-- | What the child said last, triaged or not; 'Nothing' while it has not handed back.
latest :: ChildRun -> Maybe Said
latest childRun = case reverse childRun.said of
    Heard said : _ -> Just said
    TriagedStop stop : _ -> Just (Ended stop)
    [] -> Nothing

{- | The child whose latest hand-back asks this question up: the one its
answer goes down to, and the one resumed with it.
-}
askedBy :: Fan -> QId -> Maybe ChildRun
askedBy fan qid = find ((== Just (AsksUp qid)) . latest) fan.children

-- | The task's PR as last recorded, if one was.
pullRequest :: Fan -> TaskId -> Maybe Url
pullRequest fan task =
    Map.lookup task fan.moves >>= \case
        InCi url -> Just url
        InReview url -> Just url
        Merged url -> Just url
        Kept url -> Just url
        Round url -> Just url
        Parked _ url -> url
        Delivered url -> Just url

-- | The task's children, oldest first.
childrenOf :: Fan -> TaskId -> [ChildRun]
childrenOf fan task =
    [childRun | childRun <- fan.children, childTaskId childRun.child == Tasked task]

{- | Parked, or no child of it runs and its PR is in review, merged, kept or delivered,
or its latest child finished and its PR is unrecorded. A PR in CI waits for
the 10x to record it green or parked, so a fixer's push still in flight keeps
the fan-out open. A round is open until its child's READY keeps it. A stopped
child leaves the task open: another child may take it, or the 10x parks it.
Parking settles even a child that never handed back, so a lost child cannot
keep the fan-out open.
-}
settled :: Fan -> TaskId -> Bool
settled fan task = case Map.lookup task fan.moves of
    Just (Parked _ _) -> True
    Just (InReview _) -> idle
    Just (Merged _) -> idle
    Just (Kept _) -> idle
    Just (Round _) -> False
    Just (InCi _) -> False
    Just (Delivered _) -> idle
    Nothing -> finished fan task
  where
    idle = not (any live (childrenOf fan task))

-- | The task's latest child finished.
finished :: Fan -> TaskId -> Bool
finished fan task = case latest =<< listToMaybe (reverse (childrenOf fan task)) of
    Just (Finished _) -> True
    Just (AsksUp _) -> False
    Just (Awaits _ _) -> False
    Just (Ended _) -> False
    Nothing -> False

-- | The task's latest child finished and no state of its PR is recorded: the 10x records it.
unrecorded :: Fan -> TaskId -> Bool
unrecorded fan task = finished fan task && Map.notMember task fan.moves

unsettled :: Fan -> [TaskId]
unsettled fan = [task.id | task <- tasksOf fan, not (settled fan task.id)]

{- | The tasks to spawn now, in the breakdown's order: unsettled, not a
finished task's PR in CI (awaited, not built again), no child running and no
agent at work, its last stop triaged, no question of its children open
(@asking@), and every dependency merged. No cap: how many run at once is the
10x's call, made by the dependencies it draws.
-}
spawnable :: [RunId] -> Fan -> [Task]
spawnable asking fan =
    [ task
    | task <- tasksOf fan
    , not (settled fan task.id)
    , not (inCi task.id && finished fan task.id)
    , task.id `notElem` map (.id) (busy fan)
    , Tasked task.id `notElem` map (childTaskId . fst) (untriaged fan)
    , all ((`notElem` asking) . (.child.run)) (childrenOf fan task.id)
    , all (merged fan) task.deps
    ]
  where
    inCi task = case Map.lookup task fan.moves of
        Just (InCi _) -> True
        Just (Round _) -> False
        Just (InReview _) -> False
        Just (Merged _) -> False
        Just (Kept _) -> False
        Just (Parked _ _) -> False
        Just (Delivered _) -> False
        Nothing -> False

{- | Merged: a dependent starts from the base the dependency merged into, as
GitHub Actions' @needs@ waits for success. A dependency in review, kept or
parked keeps its dependents waiting; 'settled' still lets the fan-out leave then.
-}
merged :: Fan -> TaskId -> Bool
merged fan task = case Map.lookup task fan.moves of
    Just (Merged _) -> True
    Just (Kept _) -> False
    Just (Round _) -> False
    Just (Parked _ _) -> False
    Just (InCi _) -> False
    Just (InReview _) -> False
    Just (Delivered _) -> False
    Nothing -> False

{- | The PRs in review or CI an unsettled task depends on, in the
breakdown's order: the fan-out waits for them to merge.
-}
mergesAwaited :: Fan -> [TaskId]
mergesAwaited fan =
    [dep.id | dep <- tasksOf fan, opened dep.id, any (elem dep.id . (.deps)) open]
  where
    open = [task | task <- tasksOf fan, not (settled fan task.id)]
    opened task = case Map.lookup task fan.moves of
        Just (InReview _) -> True
        Just (InCi _) -> True
        Just (Merged _) -> False
        Just (Kept _) -> False
        Just (Round _) -> False
        Just (Parked _ _) -> False
        Just (Delivered _) -> False
        Nothing -> False

-- | The PRs in CI of the tasks with no agent at work, in the breakdown's order: the 10x waits for their CI.
ciAwaited :: Fan -> [Url]
ciAwaited fan =
    [ url
    | task <- tasksOf fan
    , task.id `notElem` map (.id) (busy fan)
    , Just (InCi url) <- [Map.lookup task.id fan.moves]
    ]

-- | The tasks with an agent at work or a child running, in the breakdown's order.
busy :: Fan -> [Task]
busy fan =
    [ task
    | task <- tasksOf fan
    , Set.member task.id fan.atWork || isJust (runningOn task.id fan)
    ]

-- | The children spawned for the task so far.
tries :: Fan -> TaskId -> Int
tries fan task = length (childrenOf fan task)

{- | The task may take another child after a stop: its first child's stop
gets one retry, the Orchestrator's 'State.Run.Ask.OneRetry'; past it the
10x asks, re-plans or parks.
-}
retryLeft :: Fan -> TaskId -> Bool
retryLeft fan task = tries fan task < 2
