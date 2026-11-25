# A run is a pure fold over an event log in one SQLite store

The agent flows are state machines. A run of one must be easy to reason
about, testable as a set of laws, replayable, and never dead weight for the
agent. This ADR states how the kernel (`programs/agents/kernel`, the
`state` program) keeps a run: an append-only event log, folded by pure
code, stored in one SQLite database. ADR 0018 is the model the fold walks.

```text
state <command> --parse--> event       pure
log ++ [event]  --fold---> run state   pure, or a refusal
run state, facts --advise-> advice     pure
advice          --render--> text       pure
read git and GitHub, append, print     effect shell
```

## Principles

The preference comes from functional programming and category theory:
model the domain as algebraic data types, keep the core pure and total,
push every effect to the edge, and state the laws the core obeys so tests
can prove them. The engineering instructions apply these to all code; this
ADR applies them to the program that drives the agents.

- **Pure core.** The functions that decide what a run does are pure: same
  input, same output, no clock, no file, no network. They are the only
  place the flow's logic lives.
- **Effects at the edge.** Reading git and GitHub, the clock, appending to
  the store and printing are effects. Each is an `effectful` effect in
  `kernel/src/Effects/`, run by the shell. The core never performs one.
- **Algebraic data.** Events, states and advice are sum types with named
  constructors. Parsing turns untrusted text into these types once, at the
  edge. A line that does not parse is an error value, never skipped.
- **Total functions.** Every function on (state, event) is defined on every
  pair. A pair with no edge is a `Refusal` value; it never throws.
- **Laws as tests.** Each property below is a test, with random inputs
  where the property is universal.

## Decisions

- **Event sourcing** (Fowler's terms: event log, replay, rebuild). The only
  stored thing is an append-only log of events: facts in the past tense,
  each with a dense sequence number, a timestamp and the head commit where
  one exists. A run's state is rebuilt by replaying its log.
- **State is a fold.** `replay` (`State.Run.Fold`) folds a non-empty log
  whose first line is `started`; a log that starts otherwise is refused
  (`NotStarted`). The log is a free monoid of envelopes, and the fold is a
  partial action of it on run states: a step may be refused.
- **The kernel refuses what its flow lacks.** An event with no edge where
  the run is, a spend past a cap or a ruling the authority table forbids is
  refused: `state` exits 2 and prints `fix: <command>`. The refusal is
  logged as a `Refused` event, so the next `state next`, `state show` and
  hook warn of it. It never moves the run.
- **Loops are bounded.** Every loop holds a capped step (ADR 0020), and the
  stuck rule stops a loop that meets the same problem two rounds in a row.
- **Override is the escape.** `state override <state> <why>` moves the run
  by hand. It is the one event whose target is not a function of the graph,
  and it is logged like any other.
- **A wrong line is voided, never edited.** `state void <seq> <why>` logs a
  `Voided` reversal event; replay drops both lines, as if neither was
  logged.
- **Hook records are idempotent.** A hook record is keyed on a hash of the
  run, agent and message, so a hook that fires twice appends once.
- **Outside reads enter as events.** What GitHub shows (a draft PR, a ready
  PR) and what the run's Fuel already decides (a skip) are appended as
  events before the run advises (`due`, ADR 0016). So a replay never reads
  the world: same log, same state.
- **Advice is a function.** `state next` prints what the flow suggests now,
  with its mechanical payload filled in, from the run state and a few facts
  the shell reads (the head commit, the changed lines).
- **Fuel is an event.** The flow's first step records `fuel.set <level>`. A
  rule that depends on it is a pure function of the run state, never a
  branch the agent evaluates.
- **`state show` is the progress view.** No hand-written progress file;
  the PR body is written from the run.
- **One SQLite store per machine user**, `$XDG_STATE_HOME/state/kernel.db`
  (else `$HOME/.local/state/state/kernel.db`), holding every run. A run is
  found by its id, never by a path. Linked runs need it: a child's question
  climbs to its parent's run, and `state tasks` lists a run's children.
- **WAL mode, a 5 second busy timeout, foreign keys on**, on every
  connection. Readers never block the writer; a second writer waits.
  `synchronous = FULL` in use; `OFF` only for the test suite's throwaway
  stores (a hidden `--store-durability unsynced`).
- **Every write is `BEGIN IMMEDIATE`.** A read-decide-append takes the
  write lock before it reads, so two processes never give two events the
  same seq. The pure fold decides inside the lock.
- **Schema** in `Effects.Store`, the only module with SQL, versioned by
  `PRAGMA user_version`, one migration per change:
  - `runs(id, parent, flow, notes, created_at)`: a run's facts from its
    start. Whether it is live, finished or stopped is derived by replay.
  - `events(run, seq, json, PRIMARY KEY (run, seq))`: one envelope per row,
    append-only. `at` and `kind` are generated columns read from `json`.
  - A batch's seqs follow the log's densely from 1: a duplicate or a gap
    throws, as a writer's bug.
- **Reading out**: `state dump <run>` prints a run's envelopes, one JSON
  object per line. The self-improve analyzer opens the store read-only.

## Laws

| Law | Statement | Test |
|---|---|---|
| replay | the same log gives the same state anywhere | `FoldSpec` `live_appends_reach_the_run_the_log_replays` |
| unit | replaying `a ++ b` is replaying `a`, then appending `b` | `FoldSpec` `replaying_a_prefix_then_appending_the_rest_is_replaying_the_whole` |
| append-only | only `Effects.Store` inserts; `seq` is dense from 1 | the store throws on a gap or duplicate; one writer is assumed (ADR 0018) |
| idempotent | a hook record fired twice is logged once | `FoldSpec` `append_is_idempotent_by_id` |
| void | a void replays as the line never logged | `FoldSpec` `a_void_replays_as_the_line_never_logged` |
| total | a pair with no edge is a `Refusal`, never a throw; `-Wall -Werror` refuses a missed case | `FoldSpec` `refuses an event with no edge where the run is` |
| fixed targets | an event's target is a function of the graph, except an override | the fold |
| prose guard | the blocks the skills paste equal `state render` | `checks.agents` (`kernel/rendered.nix`) |

## The agent keeps its judgment

- **Judgment stays in prose.** Which rows to fix, how to slice a task, what
  to ask: the kernel emits the mechanical payload around those decisions
  and leaves the decision to the agent (ADR 0013).
- **Override exists.** A refusal is never a dead end: the agent can
  override, void a wrong line, or stop the run with a reason.

## Considered options

- **State in a hand-written progress file.** Rejected: it was missing in 4
  of 8 sampled runs and misnamed in 2 of those 4, and it cannot be
  replayed.
- **A mutable state file the program rewrites.** Rejected: it loses
  history, and a crash mid-write leaves half a state.
- **An advisory machine that never refuses.** Tried first, in the Python
  `state`. Dropped with it: the Haskell kernel keeps only logs that are
  paths of the flow (law Trace soundness, ADR 0018), so it refuses an
  event with no edge, logs the refusal, and keeps override as the escape.
- **A JSONL file per run, with a lock file.** Tried first, then dropped:
  linking runs by path breaks when a worktree moves, listing a run's
  children means scanning every notes directory, and the lock would be
  ours to get right, where SQLite's is tested.

## Consequences

- A run is a replayable record. The self-improve analyzer replays logs
  instead of regexing transcripts.
- The store is per machine user: runs on another machine are not linked.
- Two writers serialise on the one write lock. A run appends a few events
  per command, so the wait is short.
- Old logs need not replay: the kernel keeps no compatibility for them
  (`.claude/rules/agents-kernel.md`).

## History

- #329, #330, #331: the principles and the first `state`, in Python, over
  a JSONL log.
- #344: a refused record is logged as an event.
- #362, #376: the Haskell kernel replaces the Python program.
- #459, #461, #466, #468: one SQLite store for linked runs.
- #411: void and move; runs at any delegation depth.
- #525: questions as plain text.
