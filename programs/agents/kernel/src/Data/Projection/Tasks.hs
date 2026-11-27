{- | The tasks projection (#552 Appendix A): each breakdown a run recorded
(@breakdowns@), its epics (@epics@), each breakdown's tasks (@tasks@) and
their order (@task_dependencies@), the child runs its fan-outs spawned
(@child_runs@) and the wakes held for a task (@task_holds@).

A new breakdown starts its fan-out afresh, so the run's last state no longer
holds the older ones: a breakdown's tasks, children and holds come from the
last state of the trace that holds that breakdown (#552 s9, D10).
-}
module Data.Projection.Tasks (
    projection,
    rows,
    BreakdownRow (..),
    EpicRow (..),
    TaskRow (..),
    Progress (..),
    TaskDependencyRow (..),
    ChildRunRow (..),
    TaskHoldRow (..),
    HoldStatus (..),
    breakdownInsert,
    epicInsert,
    taskInsert,
    taskDependencyInsert,
    childRunInsert,
    taskHoldInsert,
) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Projection (
    Insert,
    Projection (..),
    Table,
    Value (..),
    enumIn,
    enumLiteral,
    insertInto,
    integer,
    nullable,
    spellings,
    strictTable,
 )
import Data.Projection.Column (runIdValue)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import State.Category.Flow (Name, nameText)
import State.Run.Ask (ChildTask (..))
import State.Run.Codec (
    branchText,
    repoText,
    shaText,
    taskIdText,
    tokenWordName,
    urlText,
 )
import State.Run.Epic (Epic, epicBranch, epicPr, epicRepo)
import State.Run.Epic qualified as Epic
import State.Run.Event (
    Base (..),
    Child (..),
    Envelope (..),
    Event (..),
    RunId,
    Said (..),
    Sha,
    Stop (..),
    StopReason (..),
    Task (..),
    TaskId,
    TaskRef (..),
    TaskState (..),
    TokenWord (..),
    Url,
 )
import State.Run.Fan (ChildRun (..), Fan (..), Heard (..))
import State.Run.Fan qualified as Fan
import State.Run.Fold (RunState (..), ScopedFan (..))
import State.Step.Artifact (EpicName, epicNameText, nonBlankText)

projection :: Projection
projection =
    Projection
        { name = "tasks"
        , version = 1
        , tables =
            breakdowns :| [epics, tasks, taskDependencies, childRuns, taskHolds]
        }

-- | The run's rows in every table of this projection, from its trace.
rows :: NonEmpty (Envelope, RunState) -> [Insert]
rows trace =
    [ breakdownInsert (BreakdownRow run seq' fan)
    | (seq', (fan, _)) <- Map.toList listed
    ]
        <> [epicInsert (EpicRow run name epic) | (name, epic) <- Map.toList final.epics]
        <> map taskInsert taskRows
        <> [ taskDependencyInsert (TaskDependencyRow run row.breakdown row.task.id after)
           | row <- taskRows
           , after <- row.task.deps
           ]
        <> map childRunInsert (childRunRows trace)
        <> map taskHoldInsert (taskHoldRows listed trace)
  where
    final = snd (NonEmpty.last trace)
    run = final.run
    listed = breakdownsIn trace
    taskRows =
        [ taskRow run seq' fan task
        | (seq', (_, fan)) <- Map.toList listed
        , task <- Fan.tasksOf fan
        ]

{- | Each breakdown any state of the trace holds, by its seq: the fan-out it
fills, and that fan-out in the last state holding it.
-}
breakdownsIn :: NonEmpty (Envelope, RunState) -> Map Natural (Name, Fan)
breakdownsIn trace =
    Map.fromList
        [ (listed.seq, (scoped.fan, fan))
        | (_, state) <- toList trace
        , (scoped, fan) <- Map.toList state.fans
        , Just listed <- [fan.breakdown]
        ]

-- | A task list a run recorded: its seq, and the fan-out it fills.
data BreakdownRow = BreakdownRow {runId :: RunId, id :: Natural, fan :: Name}
    deriving stock (Eq, Show)

-- | An epic of the run, at its stage.
data EpicRow = EpicRow {runId :: RunId, name :: EpicName, epic :: Epic}
    deriving stock (Eq, Show)

-- | An epic's stage, as its row spells it.
data EpicStatus = EpicOpen | EpicReady | EpicMerged
    deriving stock (Eq, Show, Enum, Bounded)

epicStatus :: Epic -> EpicStatus
epicStatus = \case
    Epic.Open _ -> EpicOpen
    Epic.Ready _ -> EpicReady
    Epic.Merged _ -> EpicMerged

-- | As 'State.Run.Epic.stageName' spells it, which a unit test pins.
epicStatusName :: EpicStatus -> Text
epicStatusName = \case
    EpicOpen -> "open"
    EpicReady -> "ready_for_review"
    EpicMerged -> "merged"

{- | A task of a breakdown, as the last state holding the breakdown saw it:
where it stands, its branch's last commit, and whether an agent is at work
on it.
-}
data TaskRow = TaskRow
    { runId :: RunId
    , breakdown :: Natural
    , task :: Task
    , progress :: Progress
    , head :: Maybe Sha
    , atWork :: Bool
    }
    deriving stock (Eq, Show)

-- | No PR state recorded, with no agent yet or one at it; else the state recorded last.
data Progress = Planned | Running | Moved TaskState
    deriving stock (Eq, Show)

-- | A task's status as its row spells it: 'Progress' with the state's data dropped.
data TaskStatus
    = PlannedStatus
    | RunningStatus
    | InCiStatus
    | InReviewStatus
    | RoundStatus
    | MergedStatus
    | KeptStatus
    | ParkedStatus
    | DeliveredStatus
    deriving stock (Eq, Show, Enum, Bounded)

taskStatus :: Progress -> TaskStatus
taskStatus = \case
    Planned -> PlannedStatus
    Running -> RunningStatus
    Moved (InCi _) -> InCiStatus
    Moved (InReview _) -> InReviewStatus
    Moved (Round _) -> RoundStatus
    Moved (Merged _) -> MergedStatus
    Moved (Kept _) -> KeptStatus
    Moved (Parked _ _) -> ParkedStatus
    Moved (Delivered _) -> DeliveredStatus

{- | As the log's @kind@ ('State.Run.Codec.taskStateKind') spells a task
state, which a unit test pins, and @planned@ and @running@ besides.
-}
taskStatusName :: TaskStatus -> Text
taskStatusName = \case
    PlannedStatus -> "planned"
    RunningStatus -> "running"
    InCiStatus -> "in_ci"
    InReviewStatus -> "in_review"
    RoundStatus -> "round"
    MergedStatus -> "merged"
    KeptStatus -> "kept"
    ParkedStatus -> "parked"
    DeliveredStatus -> "delivered"

{- | A task with no PR state recorded runs while an agent works on it or a
child of it runs, else is planned. A parked task's child may be resumed
('Fan.resumed' does not check the task), which leaves an agent at work on
a parked task: the row says none, as @tasks_at_work_never_planned_or_parked@
requires, since parking settled the task.
-}
taskRow :: RunId -> Natural -> Fan -> Task -> TaskRow
taskRow run seq' fan task =
    TaskRow
        { runId = run
        , breakdown = seq'
        , task
        , progress
        , head = Map.lookup task.id fan.heads
        , atWork = case progress of
            Moved (Parked _ _) -> False
            Moved (InCi _) -> working
            Moved (InReview _) -> working
            Moved (Round _) -> working
            Moved (Merged _) -> working
            Moved (Kept _) -> working
            Moved (Delivered _) -> working
            Running -> working
            Planned -> working
        }
  where
    working = Set.member task.id fan.atWork
    progress = case Map.lookup task.id fan.moves of
        Just state -> Moved state
        Nothing
            | working
                || any ((== Tasked task.id) . Fan.childTaskId . (.child)) (Fan.running fan) ->
                Running
            | otherwise -> Planned

-- | What a task's 'Base' targets, as the log's @kind@ spells it.
data BaseKind = OnDefaultKind | OnEpicKind | OnTaskKind
    deriving stock (Eq, Show, Enum, Bounded)

baseKindName :: BaseKind -> Text
baseKindName = \case
    OnDefaultKind -> "on_default"
    OnEpicKind -> "on_epic"
    OnTaskKind -> "on_task"

-- | A task waits for another of its breakdown to merge.
data TaskDependencyRow = TaskDependencyRow
    {runId :: RunId, breakdown :: Natural, task :: TaskId, after :: TaskId}
    deriving stock (Eq, Show)

{- | A child run a fan-out spawned, by the seq of its @spawned@, and the token
of its latest hand-back: none before one, and none once the hand-back has no
token of its own (a stop to re-plan or out of rounds), or the 10x triaged
its stop (#552 s9, D8).
-}
data ChildRunRow = ChildRunRow
    {runId :: RunId, id :: Natural, child :: Child, token :: Maybe TokenWord}
    deriving stock (Eq, Show)

-- | Each child of every fan-out, as the last state holding it saw it.
childRunRows :: NonEmpty (Envelope, RunState) -> [ChildRunRow]
childRunRows trace =
    [ ChildRunRow run seq' childRun.child (tokenOf childRun.said)
    | (seq', childRun) <- Map.elems children
    ]
  where
    run = (snd (NonEmpty.head trace)).run
    spawnedAt =
        Map.fromList
            [(child.run, e.seq) | (e, _) <- toList trace, Spawned child <- [e.event]]
    children =
        Map.fromList
            [ (childRun.child.run, (seq', childRun))
            | (_, state) <- toList trace
            , fan <- Map.elems state.fans
            , childRun <- fan.children
            , Just seq' <- [Map.lookup childRun.child.run spawnedAt]
            ]

tokenOf :: [Heard] -> Maybe TokenWord
tokenOf said = case reverse said of
    [] -> Nothing
    TriagedStop _ : _ -> Nothing
    Heard (Finished _) : _ -> Just ReadyWord
    Heard (AsksUp _) : _ -> Just NeedsDecisionWord
    Heard (Awaits _ _) : _ -> Just AwaitWord
    Heard (Ended stop) : _ -> case stop.reason of
        Blocked -> Just BlockedWord
        Failed -> Just FailedWord
        Replan -> Nothing
        OutOfRounds -> Nothing

{- | A wake held for a task, by the seq of its @held@: open while the last
state holding its breakdown still holds it, else acted on.
-}
data TaskHoldRow = TaskHoldRow
    { runId :: RunId
    , id :: Natural
    , task :: TaskRef
    , url :: Url
    , status :: HoldStatus
    }
    deriving stock (Eq, Show)

data HoldStatus = HoldOpen | HoldActed
    deriving stock (Eq, Show, Enum, Bounded)

holdStatusName :: HoldStatus -> Text
holdStatusName = \case
    HoldOpen -> "open"
    HoldActed -> "acted"

taskHoldRows ::
    Map Natural (Name, Fan) -> NonEmpty (Envelope, RunState) -> [TaskHoldRow]
taskHoldRows listed trace =
    [ TaskHoldRow
        e.run
        e.seq
        ref
        url
        (if stillHeld ref url then HoldOpen else HoldActed)
    | (e, _) <- toList trace
    , Held ref url <- [e.event]
    ]
  where
    stillHeld ref url =
        any (elem (ref.task, url) . (.held) . snd) (Map.lookup ref.breakdown listed)

breakdownInsert :: BreakdownRow -> Insert
breakdownInsert row =
    insertInto
        "breakdowns"
        ( ("run_id", runIdValue row.runId)
            :| [("id", integer row.id), ("fan", SqlText (nameText row.fan))]
        )

epicInsert :: EpicRow -> Insert
epicInsert row =
    insertInto
        "epics"
        ( ("run_id", runIdValue row.runId)
            :| [ ("name", SqlText (epicNameText row.name))
               , ("repo", SqlText (repoText (epicRepo row.epic)))
               , ("branch", SqlText (branchText (epicBranch row.epic)))
               , ("status", SqlText (epicStatusName (epicStatus row.epic)))
               , ("pr_url", nullable (SqlText . urlText) (epicPr row.epic))
               ]
        )

taskInsert :: TaskRow -> Insert
taskInsert row =
    insertInto
        "tasks"
        ( ("run_id", runIdValue row.runId)
            :| [ ("breakdown_id", integer row.breakdown)
               , ("id", SqlText (taskIdText row.task.id))
               , ("title", SqlText (nonBlankText row.task.title))
               , ("repo", nullable (SqlText . repoText) row.task.repo)
               , ("base_kind", SqlText (baseKindName baseKind))
               , ("base_epic_name", nullable (SqlText . epicNameText) baseEpic)
               , ("base_task_id", nullable (SqlText . taskIdText) baseTask)
               , ("head_branch", SqlText (branchText row.task.branch))
               , ("pr_url", nullable (SqlText . urlText) (Fan.statePr =<< moved))
               , ("head_sha", nullable (SqlText . shaText) row.head)
               , ("status", SqlText (taskStatusName (taskStatus row.progress)))
               , ("parked_reason", nullable SqlText parked)
               , ("at_work", SqlInteger (if row.atWork then 1 else 0))
               ]
        )
  where
    moved = case row.progress of
        Moved state -> Just state
        Running -> Nothing
        Planned -> Nothing
    parked = case moved of
        Just (Parked why _) -> Just why
        Just (InCi _) -> Nothing
        Just (InReview _) -> Nothing
        Just (Round _) -> Nothing
        Just (Merged _) -> Nothing
        Just (Kept _) -> Nothing
        Just (Delivered _) -> Nothing
        Nothing -> Nothing
    (baseKind, baseEpic, baseTask) = case row.task.base of
        OnDefault -> (OnDefaultKind, Nothing, Nothing)
        OnEpic epic -> (OnEpicKind, Just epic, Nothing)
        OnTask task -> (OnTaskKind, Nothing, Just task)

taskDependencyInsert :: TaskDependencyRow -> Insert
taskDependencyInsert row =
    insertInto
        "task_dependencies"
        ( ("run_id", runIdValue row.runId)
            :| [ ("breakdown_id", integer row.breakdown)
               , ("task_id", SqlText (taskIdText row.task))
               , ("after_task_id", SqlText (taskIdText row.after))
               ]
        )

childRunInsert :: ChildRunRow -> Insert
childRunInsert row =
    insertInto
        "child_runs"
        ( ("run_id", runIdValue row.runId)
            :| [ ("id", integer row.id)
               , ("child_run_id", runIdValue row.child.run)
               , ("breakdown_id", nullable integer ((.breakdown) <$> tasked))
               , ("task_id", nullable (SqlText . taskIdText . (.task)) tasked)
               , ("worktree", SqlText (Text.pack row.child.worktree))
               , ("handback_token", nullable (SqlText . tokenWordName) row.token)
               ]
        )
  where
    tasked = case row.child.task of
        Tasked ref -> Just ref
        Untasked -> Nothing

taskHoldInsert :: TaskHoldRow -> Insert
taskHoldInsert row =
    insertInto
        "task_holds"
        ( ("run_id", runIdValue row.runId)
            :| [ ("id", integer row.id)
               , ("breakdown_id", integer row.task.breakdown)
               , ("task_id", SqlText (taskIdText row.task.task))
               , ("url", SqlText (urlText row.url))
               , ("status", SqlText (holdStatusName row.status))
               ]
        )

breakdowns :: Table
breakdowns =
    strictTable
        "breakdowns"
        [ "  -- Each task list a 10x run recorded. A new breakdown starts a fresh set of tasks:"
        , "  -- the newest one is current, older ones stay as history."
        , ""
        , "  -- The run."
        , "  run_id TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the breakdown.done event."
        , "  id     INTEGER NOT NULL,"
        , "  -- The name of the fan-out the breakdown fills. engineers today."
        , "  fan    TEXT    NOT NULL,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)"
        ]

epics :: Table
epics =
    strictTable
        "epics"
        [ "  -- A shared branch that several task pull requests target, joined to the default branch by one final pull request."
        , ""
        , "  -- The run."
        , "  run_id TEXT NOT NULL REFERENCES runs (id),"
        , "  -- The epic's name, unique in the run."
        , "  name   TEXT NOT NULL,"
        , "  -- The repository that holds the branch, as owner/name."
        , "  repo   TEXT NOT NULL,"
        , "  -- The shared branch, such as epic/rate-limits."
        , "  branch TEXT NOT NULL,"
        , "  -- open: tasks still land on the branch. ready_for_review: its final pull request is up. merged: the user merged it."
        , "  status TEXT NOT NULL"
        , "         CONSTRAINT epics_status_enum CHECK (status IN "
            <> spellings epicStatusName
            <> "),"
        , "  -- The final pull request. Set once ready_for_review, kept when merged."
        , "  pr_url TEXT,"
        , "  PRIMARY KEY (run_id, name),"
        , "  CONSTRAINT epics_pr_url_iff_ready_or_merged CHECK ((pr_url IS NOT NULL) = (status IN "
            <> enumIn (map epicStatusName [EpicReady, EpicMerged])
            <> "))"
        ]

tasks :: Table
tasks =
    strictTable
        "tasks"
        [ "  -- One unit of a breakdown: one deliverable, one pull request, at most one agent at a time."
        , "  -- Fields only a brief reads (fuel, qa, heavy, security, shape, plan, flow, worktree)"
        , "  -- stay in the breakdown.done or task_added event."
        , ""
        , "  -- The run."
        , "  run_id        TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The breakdown the task belongs to. A task id is unique inside one breakdown only."
        , "  breakdown_id  INTEGER NOT NULL,"
        , "  -- The task's id as the breakdown names it, such as t4."
        , "  id            TEXT    NOT NULL,"
        , "  -- One line that says what the task delivers."
        , "  title         TEXT    NOT NULL,"
        , "  -- The repository the task works in, as owner/name. Optional: a breakdown may leave it out."
        , "  repo          TEXT,"
        , "  -- What the task's pull request targets."
        , "  -- on_default: the default branch. on_epic: an epic's branch. on_task: another task's branch (stacked)."
        , "  base_kind     TEXT    NOT NULL"
        , "                CONSTRAINT tasks_base_kind_enum CHECK (base_kind IN "
            <> spellings baseKindName
            <> "),"
        , "  -- The epic the task targets. Set only when on_epic."
        , "  base_epic_name TEXT,"
        , "  -- The task this one is stacked on, in the same breakdown. Set only when on_task."
        , "  base_task_id  TEXT,"
        , "  -- The branch the task's pull request comes from."
        , "  head_branch   TEXT    NOT NULL,"
        , "  -- The task's pull request. Optional: none before the first one is recorded."
        , "  pr_url        TEXT,"
        , "  -- The latest commit recorded on the pull request. Optional: none before the first task_head event."
        , "  head_sha      TEXT,"
        , "  -- planned: no agent yet. running: an agent has it and no pull request state is recorded."
        , "  -- in_ci: the pull request waits on CI. in_review: it waits on the user's review."
        , "  -- round: more work on the same pull request. merged: done. kept: a round's pull request left open on purpose."
        , "  -- parked: set aside, with a reason. delivered: done as the run's rules define it, its pull request left open."
        , "  status        TEXT    NOT NULL"
        , "                CONSTRAINT tasks_status_enum CHECK ("
        , "                  status IN " <> spellings taskStatusName <> "),"
        , "  -- Why the task is parked. Set only when parked."
        , "  parked_reason TEXT,"
        , "  -- 1 while an agent works on the task, else 0. Its own fact: a task in_ci can have a fixer at work."
        , "  at_work       INTEGER NOT NULL"
        , "                CONSTRAINT tasks_at_work_boolean CHECK (at_work IN (0, 1)),"
        , "  PRIMARY KEY (run_id, breakdown_id, id),"
        , "  FOREIGN KEY (run_id, breakdown_id) REFERENCES breakdowns (run_id, id),"
        , "  FOREIGN KEY (run_id, base_epic_name) REFERENCES epics (run_id, name),"
        , "  FOREIGN KEY (run_id, breakdown_id, base_task_id) REFERENCES tasks (run_id, breakdown_id, id),"
        , "  CONSTRAINT tasks_base_epic_name_iff_on_epic CHECK ((base_epic_name IS NOT NULL) = (base_kind = "
            <> enumLiteral (baseKindName OnEpicKind)
            <> ")),"
        , "  CONSTRAINT tasks_base_task_id_iff_on_task CHECK ((base_task_id IS NOT NULL) = (base_kind = "
            <> enumLiteral (baseKindName OnTaskKind)
            <> ")),"
        , "  CONSTRAINT tasks_base_task_id_not_self CHECK (base_task_id IS NOT id),"
        , "  CONSTRAINT tasks_parked_reason_iff_parked CHECK ((parked_reason IS NOT NULL) = (status = "
            <> enumLiteral (taskStatusName ParkedStatus)
            <> ")),"
        , "  CONSTRAINT tasks_pr_url_required_by_status CHECK ("
        , "    status NOT IN "
            <> enumIn
                ( map
                    taskStatusName
                    [ InCiStatus
                    , InReviewStatus
                    , RoundStatus
                    , MergedStatus
                    , KeptStatus
                    , DeliveredStatus
                    ]
                )
            <> " OR pr_url IS NOT NULL),"
        , "  CONSTRAINT tasks_at_work_never_planned_or_parked CHECK (at_work = 0 OR status NOT IN "
            <> enumIn (map taskStatusName [PlannedStatus, ParkedStatus])
            <> ")"
        ]

taskDependencies :: Table
taskDependencies =
    strictTable
        "task_dependencies"
        [ "  -- An ordering edge: a task starts only after another one of its breakdown is merged."
        , ""
        , "  -- The run."
        , "  run_id        TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The breakdown both tasks belong to."
        , "  breakdown_id  INTEGER NOT NULL,"
        , "  -- The task that waits."
        , "  task_id       TEXT    NOT NULL,"
        , "  -- The task it waits for."
        , "  after_task_id TEXT    NOT NULL,"
        , "  PRIMARY KEY (run_id, breakdown_id, task_id, after_task_id),"
        , "  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id),"
        , "  FOREIGN KEY (run_id, breakdown_id, after_task_id) REFERENCES tasks (run_id, breakdown_id, id),"
        , "  CONSTRAINT task_dependencies_after_task_id_not_self CHECK (after_task_id <> task_id)"
        ]

childRuns :: Table
childRuns =
    strictTable
        "child_runs"
        [ "  -- One row per child run that a run's fan-out spawned. A task can have several over time:"
        , "  -- the first, one per round, a retry. A child started outside a fan-out has no row here:"
        , "  -- runs.parent_run_id links it."
        , ""
        , "  -- The parent run."
        , "  run_id         TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the spawned event in the parent's log."
        , "  id             INTEGER NOT NULL,"
        , "  -- The child run. Its notes dir is runs.notes_dir, its state is its own run_states row."
        , "  child_run_id   TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The breakdown of the child's task. Optional: an untasked child has none."
        , "  breakdown_id   INTEGER,"
        , "  -- The task the child works on. Optional: an untasked child has none."
        , "  task_id        TEXT,"
        , "  -- The git worktree the child started in: an absolute path. A later move is in the child's own run_states row."
        , "  worktree       TEXT    NOT NULL,"
        , "  -- The token of the child's latest hand-back. NULL: it has not handed back yet,"
        , "  -- or it stopped to re-plan or out of rounds, or the run triaged its stop."
        , "  handback_token TEXT"
        , "                 CONSTRAINT child_runs_handback_token_enum CHECK ("
        , "                   handback_token IN " <> spellings tokenWordName <> "),"
        , "  PRIMARY KEY (run_id, id),"
        , "  UNIQUE (run_id, child_run_id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),"
        , "  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id),"
        , "  CONSTRAINT child_runs_task_id_iff_breakdown_id CHECK ((task_id IS NULL) = (breakdown_id IS NULL))"
        ]

taskHolds :: Table
taskHolds =
    strictTable
        "task_holds"
        [ "  -- A wake held back while a task's agent was at work: a review, a comment or a check at a URL."
        , "  -- The lead acts on it after the agent hands back."
        , ""
        , "  -- The run."
        , "  run_id       TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the held event."
        , "  id           INTEGER NOT NULL,"
        , "  -- The breakdown of the task."
        , "  breakdown_id INTEGER NOT NULL,"
        , "  -- The task the wake is for."
        , "  task_id      TEXT    NOT NULL,"
        , "  -- Where the held finding is. Compared as a plain string."
        , "  url          TEXT    NOT NULL,"
        , "  -- open: still held. acted: an acted event named the same task and url."
        , "  status       TEXT    NOT NULL"
        , "               CONSTRAINT task_holds_status_enum CHECK (status IN "
            <> spellings holdStatusName
            <> "),"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),"
        , "  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id)"
        ]
