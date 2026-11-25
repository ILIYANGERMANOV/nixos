# The agent flows follow a category model, checked by a Haskell `state`

Every agent flow (engineer, 10x, architect, chief) is one model: small typed
steps composed into flows, roles as named flows, one Fuel knob, and every
rule a law with a test. The kernel that checks it is written in Haskell, so
a flow wired wrong is a compile error, not a failed run. ADR 0020 is the
flow core, ADR 0021 its effects, ADR 0014 how a run is kept.
`docs/harness/CATEGORY-THEORY.md` explains the model at length.

## The model

The categories: [CATEGORY-THEORY, The categories](../harness/CATEGORY-THEORY.md#the-categories).

Two `Flow` terms are equal when their graphs are isomorphic up to place
renumbering, or bisimilar for loops. That this relation is a congruence
under `:>` is assumed, not tested.

Maps link them. Only what holds is claimed, and the tests check it:

- `part` turns a flow term into an open graph. It keeps identity and
  series wherever gluing succeeds (gluing refuses a loop-name clash), up to
  place renumbering: a partial functor. `graph` closes a whole flow's part
  and adds checks that do not compose (a state drawn twice, a fork never
  awaited).
- `ty` maps a run's walk back to `Cap`. It always walks from the flow's in
  port, so it keeps the empty walk and prefixes (`PathSpec`).
- `ev` maps a run to its log. `fold` is a partial action of the log on run
  states: a step may be refused (ADR 0014).
- `cfg` maps a Fuel to its skips, caps and full-review areas. It is
  monotone, a functor between preorders: a higher Fuel allows each meter at
  least the spends of the level below and skips no more (`LawsSpec`).
- `profile` is `derive` in `programs/agents/lib/derive.nix`. Tools, skills
  and operations are unions over a role's steps, so a step more never
  yields fewer. Prose is not monotone: a split role (engineer, review-lead)
  is given only the prose every step needs.
- A handler, such as a 10x answering for its engineers, wraps a flow
  without changing it (ADR 0021).

## Decisions

- **Steps are typed and come in layers.** Fuel, Gather, Plan, Build,
  Review, Ship, Fan, Request, Ticket and Pick each have a closed step kind,
  a singleton and a `Sig` per step. A step's `Outcome s leg` is tied to that
  step and the leg it leaves by, so an outcome of the wrong step is a
  compile error. `Catalog` is a closed sum of the layers, and the fold
  matches it exhaustively.
- **The table is cross-checked.** `flows/steps.nix` names each step's
  runner and flows; the kernel's layers state its types. `parseSteps`
  refuses a step without a row, a row for no step, a wire name used twice
  and an outcome no layer reads.
- **Roles are named flows with a rung.** `State/Role.hs` maps each
  `FlowName` (`State/FlowName.hs`) to its role: the wire name, the flow it
  leads and its rung, `Worker`, `Lead`, `Orchestrator` or `User`. Who
  answers a question is keyed by rung. A worker role (researcher,
  implementer, fixer) leads no flow.
- **Delegation is a handler, not a mode.** A flow never branches on who
  runs it (law Principal-blind). A question goes to the parent run, which
  rules or forwards it; with no parent it reaches the user. A role may raise
  a question to `Security`, never lower it (law Ceiling).
- **One Fuel knob.** `Low`, `Balanced` or `Max`, recorded once per run as
  `fuel.set`: the user's, or a 10x picks each child's. Fuel picks which
  optional steps a run may skip, each meter's limit and the full-review
  areas. It never rewires a flow. Every Fuel asks Confirm and ends
  merge-ready.
- **Low may skip, never must.** At Low, `refine` and `refactor` are
  skippable when the task is trivial: the agent records the skip. At
  Balanced the kernel skips the refactor at about 100 changed lines or
  fewer; Max skips nothing. The Low review sweep replaces the review agents
  only for a trivial diff.
- **Bounded loops.** Every loop holds a capped step (ADR 0020), and the
  same problem two rounds in a row stops it (the stuck rule).
- **The log is the memory.** A run is a path through its flow. State,
  pending questions and resume are folds over the log (ADR 0014).
- **A worker only stops; its lead triages.** A worker that meets a
  question the repo, brief and plan do not settle commits, pushes and hands
  back `NEEDS_DECISION`. The lead holds the goals and the user's answers,
  so it rules or forwards it with `state ask`.
- **Only leads spawn.** The lead spawns every worker; the review-lead
  spawns its reviewers. Implementers and fixers spawn nobody.
- **One plan text, passed by path.** The plan exists once, as a file. Each
  plan decision is a requirement every review checks.
- **The review loop.** Review, then pick rows, fix and re-review, until a
  pick is final, a re-review is clean, or the re-review cap is spent. The
  final fixer writes the PR body. A Not met verdict is always fixed.
- **Hand-over is a ready PR on green CI.**
- **Every law is a test.** A law names its test, or says Assumed and why.
- **Haskell for the kernel.** Typed steps and flow terms turn typed
  gluing into compile errors, and a sum type for the question
  kind makes the authority table exhaustive. The kernel tracks paths and
  routes questions; it never runs a step or calls a model.
- **An `effectful` shell.** Every IO action of `state` and `state-hook` is
  a dynamic effect in `programs/agents/kernel/src/Effects/`, one per file
  with its IO interpreter. Tests run the same shell on in-memory doubles in
  `test/Doubles/`.
- **Layered imports.** The category and its steps sit below the flows,
  roles and table, below the run, the protocol and the command line.
  `ArchitectureSpec` refuses an import from a higher layer, and IO or
  effects outside the effect modules and the shell.
- **Built from this repo's pins.** `programs/agents/kernel` uses the pinned
  `pkgs.haskellPackages` through a hand-written derivation: no second
  nixpkgs or GHC, which the cache guard refuses, and no `callCabal2nix`, an
  import from derivation (ADR 0009).

## Laws

The laws and their tests: [CATEGORY-THEORY, Laws and tests](../harness/CATEGORY-THEORY.md#laws-and-tests).

## Considered options

- **Keep Python.** Rejected: the laws stay runtime tests, and a flow wired
  wrong is found by a run, not by the compiler.
- **haskell-template as a flake input.** Rejected: it pins another nixpkgs
  channel and its own GHC.
- **`crem` for the state machines.** Rejected: not extensible with this
  model's operations.
- **Two knobs, a Quality mode and a task Size.** Replaced by one Fuel: the
  size judgment now only unlocks Low's skips, inside the level.
- **A QA gate before ready.** Rejected: it held a green PR on a question
  the user can answer later.

## Consequences

- `haskell-tests` and `haskell-lint` (hlint and fourmolu) are tech checks
  in the CI `tech` matrix.
- The skills' states and Fuel tables render from the kernel, and
  `checks.agents` keeps the pasted copies equal (`kernel/rendered.nix`).

## History

- #317, #318, #328: the engineer flow as a prose state machine.
- #351, #360, #362, #376: the category model and the Haskell kernel.
- #383: one Fuel knob.
- #499: each law names its test.
- #514, #547: refreshed with the docs.
