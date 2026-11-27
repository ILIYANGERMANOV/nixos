{- | The runs projection (#552 Appendix A): where each run stands
(@run_states@), its stays at each flow state (@step_visits@), its loops'
rounds (@loop_rounds@) and what was wrong in each (@round_problems@). Every
row is a pure function of the run's trace ('State.Run.Fold.trace').
-}
module Data.Projection.Runs (
    projection,
    rows,
    RunStateRow (..),
    StepVisitRow (..),
    LoopRoundRow (..),
    RoundProblemRow (..),
    RunStatus (..),
    ProblemKind (..),
    runStateInsert,
    stepVisitInsert,
    loopRoundInsert,
    roundProblemInsert,
) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Projection (
    Insert (..),
    Projection (..),
    Table,
    Value (..),
    enumLiteral,
    integer,
    nullable,
    spellings,
    strictTable,
 )
import Data.Projection.Column (runIdValue, timeValue)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Artifact (absPathText)
import State.Category.Flow (Name, nameText)
import State.Category.Fuel (Fuel, fuelName)
import State.Category.Step (stateNameText)
import State.Run.Codec (branchText, reasonText, repoText, urlText)
import State.Run.Event (
    Check (..),
    DraftPr (..),
    Envelope (..),
    Label (..),
    Requirement (..),
    RunId,
    Start (..),
    Stop (..),
    placeOf,
 )
import State.Run.Fold (
    Problem (..),
    Round (..),
    RunState (..),
    fuelOf,
    nodeName,
    over,
    recordedPr,
 )

projection :: Projection
projection =
    Projection
        { name = "runs"
        , version = 1
        , tables = runStates :| [stepVisits, loopRounds, roundProblems]
        }

-- | The run's rows in every table of this projection, from its trace.
rows :: NonEmpty (Envelope, RunState) -> [Insert]
rows trace =
    runStateInsert (runStateRow trace)
        : map stepVisitInsert (stepVisitRows trace)
            <> map loopRoundInsert loopRounds'
            <> map roundProblemInsert problems
  where
    (loopRounds', problems) = roundRows trace

-- | Where a run stands: one row per run.
data RunStateRow = RunStateRow
    { runId :: RunId
    , status :: RunStatus
    , step :: Text
    , fuel :: Fuel
    , goal :: Maybe Text
    , worktree :: Text
    , repo :: Maybe Text
    , prUrl :: Maybe Text
    , baseBranch :: Maybe Text
    , headBranch :: Maybe Text
    , ticketUrl :: Maybe Text
    }
    deriving stock (Eq, Show)

-- | Whether the flow goes on, a stop ended it, and which, or it reached its end.
data RunStatus = Active | Stopped Stop | Finished
    deriving stock (Eq, Show)

-- | A run's status as its row spells it: 'RunStatus' with the stop dropped.
data StatusCase = ActiveCase | StoppedCase | FinishedCase
    deriving stock (Eq, Show, Enum, Bounded)

statusCase :: RunStatus -> StatusCase
statusCase = \case
    Active -> ActiveCase
    Stopped _ -> StoppedCase
    Finished -> FinishedCase

statusName :: StatusCase -> Text
statusName = \case
    ActiveCase -> "active"
    StoppedCase -> "stopped"
    FinishedCase -> "finished"

-- | A stay of a run at one flow state: from the line that moved it in, until the next one that moved it.
data StepVisitRow = StepVisitRow
    { runId :: RunId
    , id :: Natural
    , step :: Text
    , enteredAt :: UTCTime
    , leftAt :: Maybe UTCTime
    }
    deriving stock (Eq, Show)

-- | A round of a loop, by the line that opened it.
data LoopRoundRow = LoopRoundRow {runId :: RunId, loop :: Name, id :: Natural, ordinal :: Natural}
    deriving stock (Eq, Show)

-- | A problem still open in a loop's round.
data RoundProblemRow = RoundProblemRow
    { runId :: RunId
    , loop :: Name
    , loopRoundId :: Natural
    , kind :: ProblemKind
    , name :: Text
    }
    deriving stock (Eq, Show)

-- | A 'Problem''s kind: a review row picked to fix, a requirement not met, a red CI check.
data ProblemKind = RowProblem | UnmetProblem | FailingProblem
    deriving stock (Eq, Show, Enum, Bounded)

problemKindName :: ProblemKind -> Text
problemKindName = \case
    RowProblem -> "row"
    UnmetProblem -> "unmet"
    FailingProblem -> "failing"

problemOf :: Problem -> (ProblemKind, Text)
problemOf = \case
    Row (Label label) -> (RowProblem, label)
    Unmet (Requirement requirement) -> (UnmetProblem, requirement)
    Failing (Check check) -> (FailingProblem, check)

runStateRow :: NonEmpty (Envelope, RunState) -> RunStateRow
runStateRow trace =
    RunStateRow
        { runId = state.run
        , status
        , step = stateNameText (nodeName state.at)
        , fuel = fuelOf state
        , goal = state.start.goal
        , worktree = Text.pack (absPathText worktree)
        , repo = repoText <$> repo
        , prUrl = urlText <$> recordedPr state
        , baseBranch = branchText . (.base) <$> state.drafted
        , headBranch = branchText . (.branch) <$> state.drafted
        , ticketUrl = urlText <$> state.ticket
        }
  where
    state = snd (NonEmpty.last trace)
    (worktree, repo) = placeOf state.start (fmap fst trace)
    status = case state.stopped of
        Just stop -> Stopped stop
        Nothing
            | over state -> Finished
            | otherwise -> Active

{- | Each stay: a line moves the run in when the state it leaves the run at
differs from the one before, or when it opens a round, as a loop's back edge
to the state it leaves does. A line that passes through states by itself
('State.Run.Fold.joined') stays only at the last one.
-}
stepVisitRows :: NonEmpty (Envelope, RunState) -> [StepVisitRow]
stepVisitRows trace =
    zipWith
        ( \(e, state) next -> StepVisitRow state.run e.seq (stateNameText (nodeName state.at)) e.ts next
        )
        entered
        (map (Just . (.ts) . fst) (drop 1 entered) <> [Nothing])
  where
    lines' = toList trace
    entered =
        [ line
        | (line, before) <- zip lines' (Nothing : map (Just . snd) lines')
        , moves before line
        ]
    moves before (e, after) = case before of
        Nothing -> True
        Just state ->
            state.at /= after.at
                || any (any ((== e.seq) . (.opened))) (Map.elems after.rounds)

{- | Every round any line's run holds, and its problems as the last run
holding it saw them: a round left is gone from the runs after it. The rounds
are keyed by their loop and opening seq; were one line to open two rounds of
one loop, the later one stands for both.
-}
roundRows ::
    NonEmpty (Envelope, RunState) -> ([LoopRoundRow], [RoundProblemRow])
roundRows trace =
    ( [ LoopRoundRow run loop opened ordinal
      | ((loop, opened), (ordinal, _)) <- Map.toList seen
      ]
    , [ RoundProblemRow run loop opened kind name
      | ((loop, opened), (_, found)) <- Map.toList seen
      , (kind, name) <- map problemOf (Set.toList found)
      ]
    )
  where
    run = (snd (NonEmpty.head trace)).run
    seen =
        Map.fromList
            [ ((loop, r.opened), (ordinal, r.found))
            | (_, state) <- toList trace
            , (loop, rounds) <- Map.toList state.rounds
            , (ordinal, r) <- zip [1 ..] (toList rounds)
            ]

runStateInsert :: RunStateRow -> Insert
runStateInsert row =
    Insert
        "run_states"
        ( ("run_id", runIdValue row.runId)
            :| [ ("status", SqlText (statusName (statusCase row.status)))
               , ("step", SqlText row.step)
               , ("stop_reason", nullable (SqlText . reasonText . (.reason)) stop)
               , ("stop_detail", nullable (SqlText . (.why)) stop)
               , ("fuel", SqlText (fuelName row.fuel))
               , ("goal", nullable SqlText row.goal)
               , ("worktree", SqlText row.worktree)
               , ("repo", nullable SqlText row.repo)
               , ("pr_url", nullable SqlText row.prUrl)
               , ("base_branch", nullable SqlText row.baseBranch)
               , ("head_branch", nullable SqlText row.headBranch)
               , ("ticket_url", nullable SqlText row.ticketUrl)
               ]
        )
  where
    stop = case row.status of
        Stopped s -> Just s
        Active -> Nothing
        Finished -> Nothing

stepVisitInsert :: StepVisitRow -> Insert
stepVisitInsert row =
    Insert
        "step_visits"
        ( ("run_id", runIdValue row.runId)
            :| [ ("id", integer row.id)
               , ("step", SqlText row.step)
               , ("entered_at", timeValue row.enteredAt)
               , ("left_at", nullable timeValue row.leftAt)
               ]
        )

loopRoundInsert :: LoopRoundRow -> Insert
loopRoundInsert row =
    Insert
        "loop_rounds"
        ( ("run_id", runIdValue row.runId)
            :| [ ("loop", SqlText (nameText row.loop))
               , ("id", integer row.id)
               , ("ordinal", integer row.ordinal)
               ]
        )

roundProblemInsert :: RoundProblemRow -> Insert
roundProblemInsert row =
    Insert
        "round_problems"
        ( ("run_id", runIdValue row.runId)
            :| [ ("loop", SqlText (nameText row.loop))
               , ("loop_round_id", integer row.loopRoundId)
               , ("kind", SqlText (problemKindName row.kind))
               , ("name", SqlText row.name)
               ]
        )

runStates :: Table
runStates =
    strictTable
        "run_states"
        [ "  -- Where a run stands now. One row per run."
        , ""
        , "  -- The run."
        , "  run_id      TEXT NOT NULL PRIMARY KEY REFERENCES runs (id),"
        , "  -- active: the flow goes on. stopped: a stop event ended it. finished: the flow reached its end."
        , "  status      TEXT NOT NULL"
        , "              CONSTRAINT run_states_status_enum CHECK (status IN "
            <> spellings statusName
            <> "),"
        , "  -- The flow state the run is at, such as review or gather/researchers. out or exit once finished."
        , "  step        TEXT NOT NULL,"
        , "  -- Why the run stopped. Set only when stopped."
        , "  stop_reason TEXT"
        , "              CONSTRAINT run_states_stop_reason_enum CHECK (stop_reason IN "
            <> spellings reasonText
            <> "),"
        , "  -- The stop's own words. Set only when stopped."
        , "  stop_detail TEXT,"
        , "  -- The run's Fuel: how many tokens and how much time it may spend. balanced until a fuel.set event."
        , "  fuel        TEXT NOT NULL"
        , "              CONSTRAINT run_states_fuel_enum CHECK (fuel IN "
            <> spellings fuelName
            <> "),"
        , "  -- The user's goal, word for word, from the started event. Optional: a run started with none has none."
        , "  goal        TEXT,"
        , "  -- The git worktree the run works in: an absolute path. The latest worktree_moved event wins."
        , "  worktree    TEXT NOT NULL,"
        , "  -- The repository the run works in, as owner/name. Optional: a worktree with no GitHub remote has none."
        , "  repo        TEXT,"
        , "  -- The run's own pull request. Optional: none before the draft."
        , "  pr_url      TEXT,"
        , "  -- The branch the run's pull request targets. Optional: none before the draft."
        , "  base_branch TEXT,"
        , "  -- The branch the run's pull request comes from. Optional: none before the draft."
        , "  head_branch TEXT,"
        , "  -- The ticket the run wrote. Optional: most runs write none."
        , "  ticket_url  TEXT,"
        , "  CONSTRAINT run_states_stop_reason_iff_stopped CHECK ((stop_reason IS NOT NULL) = (status = "
            <> enumLiteral (statusName StoppedCase)
            <> ")),"
        , "  CONSTRAINT run_states_stop_detail_iff_stopped CHECK ((stop_detail IS NOT NULL) = (status = "
            <> enumLiteral (statusName StoppedCase)
            <> "))"
        ]

stepVisits :: Table
stepVisits =
    strictTable
        "step_visits"
        [ "  -- Each stay of a run at one flow state, in order. A loop visits a state again: a new row."
        , ""
        , "  -- The run."
        , "  run_id     TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the event that moved the run into the state."
        , "  id         INTEGER NOT NULL,"
        , "  -- The flow state's name, such as plan or gather/notes."
        , "  step       TEXT    NOT NULL,"
        , "  -- The time of the event that moved the run in."
        , "  entered_at TEXT    NOT NULL,"
        , "  -- The time of the event that moved the run on. NULL: the run is here now."
        , "  left_at    TEXT,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)"
        ]

loopRounds :: Table
loopRounds =
    strictTable
        "loop_rounds"
        [ "  -- Each round of a flow loop a run went through, such as a review round or a CI fix round."
        , ""
        , "  -- The run."
        , "  run_id  TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The loop's name in the flow: plan, gather, fix, ci or round."
        , "  loop    TEXT    NOT NULL,"
        , "  -- The seq of the event that opened this round. One event can open a round of several loops."
        , "  id      INTEGER NOT NULL,"
        , "  -- The round's number inside this pass through the loop, from 1."
        , "  ordinal INTEGER NOT NULL,"
        , "  PRIMARY KEY (run_id, loop, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)"
        ]

roundProblems :: Table
roundProblems =
    strictTable
        "round_problems"
        [ "  -- What was still wrong in a loop round. The same problems two rounds in a row mean the run is stuck."
        , ""
        , "  -- The run."
        , "  run_id        TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The loop of the round."
        , "  loop          TEXT    NOT NULL,"
        , "  -- The round: loop_rounds.id."
        , "  loop_round_id INTEGER NOT NULL,"
        , "  -- row: a review finding picked to fix. unmet: a requirement judged not met. failing: a red CI check."
        , "  kind          TEXT    NOT NULL"
        , "                CONSTRAINT round_problems_kind_enum CHECK (kind IN "
            <> spellings problemKindName
            <> "),"
        , "  -- The finding's label, the requirement's text or the check's name."
        , "  name          TEXT    NOT NULL,"
        , "  PRIMARY KEY (run_id, loop, loop_round_id, kind, name),"
        , "  FOREIGN KEY (run_id, loop, loop_round_id) REFERENCES loop_rounds (run_id, loop, id)"
        ]
