# An append-only event store with rebuilt projections

ADR 0014 keeps a run as a pure fold over an event log in one SQLite store.
That store held each event as one JSON envelope of one wire version (ADR
0020), and a log of another version was refused. So one renamed step made a
whole older run unreadable. This ADR makes the log a permanent store of
facts that every later binary can read. Design: #552.

It amends ADR 0014 and ADR 0020:

| ADR | Text | Now |
|---|---|---|
| 0014 | "A line that does not parse is an error value, never skipped" | a stored event that does not parse is kept and decodes to `Unknown` |
| 0014 | Event sourcing: "The only stored thing is an append-only log" | three permanent tables; typed tables are projections of `events` |
| 0014 | Schema: `Effects.Store`, the only module with SQL; `events(run, seq, json)` | `Effects.Store.*` speaks SQL; the envelope is columns, `data` the payload |
| 0014 | Consequence: "Old logs need not replay" | logs replay forever |
| 0020 | "Wire version 4 ... A log with an older version or a removed event is refused" | each event type has its own `schema_version`; no log is refused for its age |

```text
state command --append, one transaction--> runs, events, blobs   permanent, append-only
events        --decode, fold------------> trace                  pure
trace         --rows, same transaction--> projections            rebuilt, never written by hand
```

## Decisions

- **Three permanent tables, in `kernel-v2.db`.** `events` is the only
  truth: one row per event, its envelope as columns and its payload as
  `data`, one JSON object. `runs` is a write-once index of each run's
  first event, inserted in that event's transaction. `blobs` holds file
  content by sha256. Triggers make all three append-only: UPDATE, DELETE
  and `INSERT OR REPLACE` abort. A wrong line is voided by a new event
  (ADR 0014).
- **A file of our own.** The first migration sets `application_id`
  1263685196 (the bytes `KRNL`) and `user_version`. Open refuses a file
  with another `application_id` or a newer `user_version`, before it
  writes anything.
- **Each event type has its own `schema_version`**, from 1. A new
  optional key is no bump. A removed, renamed or re-typed key bumps the
  type's version and adds one total upcaster. A renamed type adds an
  alias. Upcasting runs at read time only: a stored event never changes.
- **Decode is total.** Every row decodes to one of three cases:

  | Case | Meaning | The run |
  |---|---|---|
  | `Known` | an event this binary reads, upcast to its latest version | goes on |
  | `Retired {type, data}` | a type that left the domain; its decoder stays | goes on: the fold skips it |
  | `Unknown {type, schema_version, data}` | an unknown type, a newer version or a payload that does not fit | dump, reports and SQL read it; append and resume refuse, naming the seq and the type |

  A decoder is never deleted. Without `Retired`, every old run holding a
  removed type would decode to `Unknown` and freeze.
- **Typed tables are projections**, rebuilt per run in the append's
  transaction from the fold's trace. They take no writes of their own, so
  dropping one loses nothing.
- **Three layers, each pure but the last.**

  ```text
  Domain  <-  Data  <-  Effects/Store
   pure       pure       IO, SQL only
  ```

  - `State/` is the domain: the events and states the fold decides on.
  - `Data/` is the database's shape: column codecs (`Field.hs`), one row
    type per table (`Entity/`), the alias table (`Payload/Upcast.hs`) and
    the pure mapping between events and rows (`Payload/Event.hs`).
  - `Effects/Store/` runs SQL on rows: `Connection.hs`, `Migration.hs`,
    `Events.hs`. It holds no row type and no mapping.

  `ArchitectureSpec` holds the rule, as it holds the kernel's other
  layers. Every mapping is pure, so round trips are property tests with
  no database.
- **`state dump` prints the raw rows**: JSON Lines, one object per
  `events` row, every column but `position` a key and `data` as stored.
  `position` is SQLite's rowid alias: store-internal append order the
  kernel never reads. Dump never decodes a payload, so it never fails on
  a row.

## Laws

The log laws and their tests: [CATEGORY-THEORY, Log](../harness/CATEGORY-THEORY.md#log).

## Considered options

- **Keep one wire version and refuse older logs.** Rejected: one bad line
  hides a whole run, and a rename makes every older run unreadable.
- **Migrate stored events in place.** Rejected: it edits facts. Upcasting
  on read keeps every stored byte and gives the same events.
- **Row types and mappings inside `Effects/Store/`.** Rejected: the
  mappings would need a database to test. In `Data/` they are pure.
- **Migrate `kernel.db` into the new file.** Rejected for now: the new
  store is a new file, `kernel-v2.db`, next to an untouched `kernel.db`.
  A run that lives only in `kernel.db` is not found.

## Consequences

- A stored event is read by every later binary, as `Known`, `Retired` or
  `Unknown`.
- An `Unknown` event freezes its run until a binary that knows it is
  installed.
- Live runs in `kernel.db` do not carry over: finish or stop them before
  the switch.
- A file snapshotted into `blobs` by mistake is removed by hand: drop
  `blobs_no_delete`, delete the row, recreate the trigger.

## History

- #552: the append-only event store, the `Data/` layer and total decode.
  Projections follow in later slices of the same issue.
