# The agent flows follow a category model, checked by a Haskell `state`

ADR 0012 made `/engineer` a state machine in prose and ADR 0015 made `state`
the Python program that records it. Both describe one flow by hand. #351
settles a model for every flow: small typed steps glued into reusable blocks,
roles as named flows, and every rule a law with a test. This ADR records that
model in brief and replaces ADR 0015's choice of Python for `state` with
Haskell. Design: #351; implementation plan: #360.

Supersedes ADR 0015's choice of Python. Its JSONL log stayed until ADR 0022
moved the log to one SQLite database.

## The model

| Category | Objects | Arrows | Plain words |
|---|---|---|---|
| `Cap` | artifact types: `Ctx`, `Plan`, `Diff`, `PR` | outcome edges `step.outcome : A -> B` | the vocabulary |
| `Flow` | typed ports | terms: `;`, `+`, `loop_n`, `opt`, `par_k` | how steps are wired |
| `Run(F)` | states of flow `F` | paths | what happened |
| `Ifc` | the operations a role may call | handlers | who answers |
| `Mode` | Fuel: `Low`, `Balanced`, `Max` | `<=`, a chain | how much work |
| `Log` | one object | lists of events | memory |
| `Prof` | tools, prose, operations | inclusion | what an agent is given |

Maps link them: `graph` turns a flow term into its state machine, `ty`
maps a run back to the vocabulary, `ev` maps a run to its log, `cfg` maps a
mode to its skips, fuel, fan-out and full-review areas, and `profile` derives
a role's tools and prose from its steps. A handler, such as a 10x answering
for its engineers, wraps a flow without changing it.

Not every map is a functor, and the tests check only what holds:

- `ty` always walks from the flow's in port, so `ty (p ++ q) = ty p ; ty q`
  does not typecheck: `q` starts mid-flow. `ty` is a plain function from
  walks to `Cap` paths that keeps the empty walk (`ty [] = []`) and
  prefixes (`ty p` is a prefix of `ty (p ++ q)`). `PathSpec` tests both.
- `cfg` is monotone: a higher Fuel allows each meter at least the spends of
  the level below and skips no more (`LawsSpec`, over every flow in
  `State.Role.roles`).
- `profile` is `derive` in `programs/agents/lib/derive.nix`. Tools, skills
  and operations are unions over a role's steps, so a step more never yields
  fewer: `derived_role_grows_with_its_steps` checks it for the table less any
  one row, and union makes any smaller table follow. Prose is not monotone:
  a split role (engineer, review-lead) is given the prose every step needs,
  an intersection, so a step more may give less prose.

## Decisions

- **Capabilities and blocks.** Each step is defined once and typed. Steps glue
  into the blocks Gather, Propose, Build, Review, Describe and Ship; a flow is
  a few blocks in a row, and any flow can be one step of a bigger one.
  Superseded by ADR 0019: blocks are composable flows, loop rounds are step meters.
- **Roles are named flows.** `engineer : Ctx -> PR`. A 10x runs whole Engineer
  flows, as the user would run N engineers by hand.
- **Delegation is a handler, not a mode.** A flow never branches on who runs
  it. A question goes to the parent, which answers it or passes it up; with no
  parent, or when it needs the user, it reaches the user. A role may raise a
  question to `Security`, never lower it.
- **Modes skip, they never rewire.** The mode (Fuel, once Quality x Size) picks which optional steps
  collapse to identity, each loop's fuel, each fan-out and the full-review
  areas. A higher mode skips less and grows the rest (Monotone).
- **Bounded loops.** Every loop has fuel, and the same problem two rounds in a
  row stops it.
- **The log is the memory.** A run is a path through its flow; events go to
  one append-only log, a SQLite database since ADR 0022, and state, pending
  questions and resume are folds over it.
- **Every law is a test.** Typed gluing, Skip is endo, Trace soundness,
  Deterministic, Keep, Monotone, Principal-blind, Ceiling, Total, Bounded, Log,
  Sufficient, Lean and Budget: #351 states each.
- **Haskell for the kernel.** A `Step a b` GADT turns Typed gluing and Skip is
  endo into compile errors, and a sum type for the question kind makes the
  authority table exhaustive. The kernel is a pure core with a thin
  `effectful` shell; `state` tracks paths and routes questions, and never runs
  a step or calls a model.
- **Built from this repo's pins.** `programs/agents/kernel` uses the pinned
  `pkgs.haskellPackages` (GHC 9.10.3) through a hand-written derivation: no
  second nixpkgs or GHC, which the cache guard refuses, and no
  `callCabal2nix`, an import from derivation (ADR 0009). The cabal, test and
  lint setup is copied from Ivy-Apps/haskell-template, without relude.
- **An `effectful` shell, at the user's request.** Every IO action of `state`
  and `state-hook` is a dynamic effect in `programs/agents/kernel/src/Effects/`,
  one per file with its IO interpreter; the mains only run the interpreters.
  Tests run the same shell on in-memory doubles in `test/Doubles/`, and
  `ArchitectureSpec` keeps IO and effects out of every module but the
  effects' and the shell's. #360 planned a plain IO shell; the user asked for
  algebraic effects mid-stack, and one extra PR added them.

## Amendment: step layers, typed outcomes, sums, a role registry

PR #376 reorganised the kernel; the model above holds.

- **Steps come in layers.** Gather, Plan, Build, Review, Ship and Fan each
  have a closed step kind, a singleton and a `Sig` per step. A step's
  `Outcome s leg` is tied to that step and to the leg it leaves by (exit or
  continue), so an outcome of the wrong step or leg is a compile error. The
  global outcome sum and its hand-written event table are gone: `Catalog` is
  a closed sum of the layers, and the fold matches it exhaustively, so a new
  layer breaks the build until each match handles it.
- **The table is cross-checked.** `parseSteps` refuses a step without a row,
  a row for no step, wrong types or outcomes, a wire name used twice and an
  outcome no layer reads.
- **Roles are named flows with a rung.** `State/Role.hs` maps each
  `FlowName` to its role: the wire name, the flow it leads and its rung,
  `Worker`, `Lead`, `Orchestrator` or `User`. Who answers a question is keyed
  by rung, so a new role on an existing rung inherits its row. The log's flow
  name, the run's graph and the fan-out's child role are read from the
  registry. A worker role (researcher, implementer, fixer) leads no flow and
  is no entry; `parseSteps` refuses a `steps.nix` row whose `flows` names no
  role, or whose `runner` leads a flow.
- **Sums for branching.** `Ty` has `a :+ b`. A step whose out is a sum has
  two continue outcomes, legs `Inl` and `Inr`, and no exit; each summand is
  one type, not a sum. `inl` and `inr` inject, and `f ||| g` is the case that
  runs `f` on the left summand and `g` on the right. Inside `graph` a part has
  one in port per summand, so each branch is glued to its own edge; a whole
  flow still has one in port and one end, and draws only the states a run can
  reach. `Opt` and `Loop` refuse a sum (`NotSum`): a skip or a loop's way back
  is one edge, and a sum would need one per summand. Loop ids are unique
  across branches too, as `graph`'s loops are keyed by id. No shipped flow
  branches yet, so the wire format is unchanged.
- **Layered imports.** The category and its steps sit below the flows, roles
  and table, below the run, the protocol and the command line;
  `ArchitectureSpec` refuses an import from a higher layer.

## Amendment: one Fuel knob

PR #383 replaced the two knobs; the model above holds.

- **Fuel replaces Quality x Size.** One level, `Low`, `Balanced` or `Max`,
  set once per task: the user's, or a 10x picks each child's and never asks.
  POC, `Size: Trivial` and the `GREW` hand-back are gone. This reverses ADR
  0012's rejection of Trivial as a mode: the size judgment now only unlocks
  Low's skips, inside the level.
- **The loop budget is `rounds`.** The old internal `fuel` became `rounds`, so
  the word means one thing.
- **Low may skip, never must.** At Low, research, the simplify pass and the
  refactor are skippable when the task is trivial: the agent records the skip,
  the kernel never does. Confirm is asked at every Fuel, and every Fuel ends
  merge-ready.
- **The Low sweep has a safety floor.** One review-lead sweep replaces the
  review agents only for a trivial diff; CI, auth, database, secrets, deploy,
  the data model or over about 100 changed lines get the full review as at
  Balanced, DEEP where the tier says.

## Amendment: each law names its test

#499 checked each law against the code. A law is a test, or it says
Assumed and why.

| Law | Backed by |
|---|---|
| Monotone | `LawsSpec` PerFuel, over every flow in `State.Role.roles`; `derived_role_grows_with_its_steps` for tools, skills and operations, not prose |
| Keep | `LawsSpec`: no Fuel skip (`termSkips`) of any role's flow names `review`, `re_review`, `research`, `describe`, `visual` or `simplify_pr`. A flow without one of these steps holds it vacuously |
| Log | Replay: `FoldSpec` `replaying_a_prefix_then_appending_the_rest_is_replaying_the_whole` and `live_appends_reach_the_run_the_log_replays`. One writer: Assumed. Only `Effects.Store` inserts events, but nothing stops an agent writing the database with `sqlite3` |
| Sufficient | `derived_role_holds_every_step_need`, in `checks.agents` (`derived-roles`) |
| Lean | `derived_role_holds_nothing_else`, in `checks.agents` (`derived-roles`) |
| Budget | `budget-compare` over every size and ceiling, which fails `checks.claude-config` (`programs/claude-code/config-check.nix`) |

## Considered options

- **Keep Python.** Rejected: the laws stay runtime tests, and a flow wired
  wrong is found by a run, not by the compiler.
- **haskell-template as a flake input.** Rejected: it pins another nixpkgs
  channel and its own GHC.
- **`crem` for the state machines.** Rejected: not extensible with this
  model's operations.

## Consequences

- `haskell-tests` (the package's own test suite) and `haskell-lint` (hlint and
  fourmolu) join the tech checks and the CI `tech` matrix.
- The kernel's `state` and `state-hook` replaced the Python `state` in
  #360's PR 4, and `programs/agents/state/` is gone.
