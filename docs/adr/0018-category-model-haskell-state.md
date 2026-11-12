# The agent flows follow a category model, checked by a Haskell `state`

ADR 0012 made `/engineer` a state machine in prose and ADR 0015 made `state`
the Python program that records it. Both describe one flow by hand. #351
settles a model for every flow: small typed steps glued into reusable blocks,
roles as named flows, and every rule a law with a test. This ADR records that
model in brief and replaces ADR 0015's choice of Python for `state` with
Haskell. Design: #351; implementation plan: #360.

Supersedes ADR 0015's choice of Python. Its JSONL log stays.

## The model

| Category | Objects | Arrows | Plain words |
|---|---|---|---|
| `Cap` | artifact types: `Ctx`, `Plan`, `Diff`, `PR` | outcome edges `step.outcome : A -> B` | the vocabulary |
| `Flow` | typed ports | terms: `;`, `+`, `loop_n`, `opt`, `par_k` | how steps are wired |
| `Run(F)` | states of flow `F` | paths | what happened |
| `Ifc` | the operations a role may call | handlers | who answers |
| `Mode` | Quality x Size | `<=` | how much work |
| `Log` | one object | lists of events | memory |
| `Prof` | tools, prose, operations | inclusion | what an agent is given |

Functors link them: `graph` turns a flow term into its state machine, `ty`
maps a run back to the vocabulary, `ev` maps a run to its log, `cfg` maps a
mode to its skips, fuel, fan-out and full-review areas, and `profile` derives
a role's tools and prose from its steps. A handler, such as a 10x answering
for its engineers, wraps a flow without changing it.

## Decisions

- **Capabilities and blocks.** Each step is defined once and typed. Steps glue
  into the blocks Gather, Propose, Build, Review, Describe and Ship; a flow is
  a few blocks in a row, and any flow can be one step of a bigger one.
- **Roles are named flows.** `engineer : Ctx -> PR`. A 10x runs whole Engineer
  flows, as the user would run N engineers by hand.
- **Delegation is a handler, not a mode.** A flow never branches on who runs
  it. A question goes to the parent, which answers it or passes it up; with no
  parent, or when it needs the user, it reaches the user. A role may raise a
  question to `Security`, never lower it.
- **Modes skip, they never rewire.** Quality x Size picks which optional steps
  collapse to identity, each loop's fuel, each fan-out and the full-review
  areas. A higher mode skips less and grows the rest (Monotone).
- **Bounded loops.** Every loop has fuel, and the same problem two rounds in a
  row stops it.
- **The log is the memory.** A run is a path through its flow; events go to
  one append-only JSONL log, and state, pending questions and resume are folds
  over it.
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
- The Python `state` stays installed until the kernel replaces it in #360's
  PR 4; until then the kernel's `state` and `state-hook` are stubs nothing
  installs.
