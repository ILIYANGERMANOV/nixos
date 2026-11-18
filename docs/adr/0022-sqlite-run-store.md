# The kernel's run store: one SQLite database in WAL mode

ADR 0014 kept each run's events in its own append-only `events.jsonl`, and
rejected a database "for a single run". The chief changed the premise: it
runs several requests and links runs to each other. A child's question
climbs to its parent's run, a parent answers it from its own, and `state
tasks` lists a run's children. Two `state` processes now write at once (a
parent and its child, two siblings), and a run must find the runs linked to
it without knowing their notes directories. Design: #461 (slice S1);
implementation: PR #466.

## Decision

- **One database per machine user**, `$XDG_STATE_HOME/state/kernel.db`
  (else `$HOME/.local/state/state/kernel.db`), holding every run. A run is
  found by its id, never by a path.
- **WAL mode, a 5s busy timeout, foreign keys on**, set on every
  connection. Readers never block the writer, and a second writer waits for
  the first instead of failing.
- **`synchronous = FULL` in use; `OFF` only in the test suite.** Opening
  the store takes a `Durability`. The E2E specs pass a hidden leading
  `--store-durability unsynced` for their throwaway stores: each `state`
  call's close checkpoints the WAL, ~4ms of fsyncs, which made the suite
  ~30% slower than over the unsynced JSONL logs.
- **Every write is `BEGIN IMMEDIATE`.** A read-decide-append takes the
  write lock before it reads, so two processes never give two events the
  same seq. The pure fold decides inside the lock, as it did over the file.
- **Schema** (`Effects.Store`, the only module with SQL), versioned by
  `PRAGMA user_version`, one migration per change, each in its own
  immediate transaction:
  - `runs(id PRIMARY KEY, parent REFERENCES runs, flow, notes, created_at)`:
    the run's facts from its start. `parent` links a child to its parent's
    run; whether a run is live, finished or stopped is derived by replaying
    its events, never stored.
  - `events(run REFERENCES runs, seq, json, PRIMARY KEY (run, seq))`: each
    row one envelope as `State.Run.Codec` encodes it, append-only. `at` and
    `kind` are generated columns read from `json`, so they cannot drift.
  - A batch's seqs follow the log's densely from 1: a duplicate or a gap
    throws, as a writer's bug.
  - A run's children are listed in the order their starts were written (the
    rowid), oldest first.
- **Reading out**: `state dump <run>` prints a run's envelopes, one JSON
  object per line. The self-improve analyzer opens the database
  read-only.

## Considered options

- **JSONL, hardened**: a lock file per log, and a parent's path in each
  child's start. Rejected: linking runs by path breaks when a worktree
  moves or is removed, listing a run's children means scanning every notes
  directory, and the lock and the append would be ours to get right, where
  SQLite's are tested.
- **JSONL now, a database later.** Rejected: the chief's linked runs need
  the store now, and moving later would migrate twice the code and twice
  the logs.

## Consequences

- A run in flight on a JSONL log does not resume: its events are not in
  the database, and the kernel does not import old logs (the kernel keeps
  no compatibility for old logs; `.claude/rules/agents-kernel.md`).
- The store is per machine user: runs on another machine, or under another
  user, are not linked.
- Two writers serialise on the database's one write lock. A run appends a
  few events per command, so the wait is short; the busy timeout bounds it.
- ADR 0014's "A database. Rejected" holds no longer: this ADR replaces it.
  ADR 0015's JSONL log is superseded likewise.
