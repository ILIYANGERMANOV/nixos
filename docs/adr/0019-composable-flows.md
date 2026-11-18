# Flows compose from small lawful flows

ADR 0018 glued steps into fixed blocks (Gather, Propose, Build, Review,
Describe, Ship). A block was a closed enum in the kernel, so a new flow meant
new enum cases, and its budgets were special cases: `rounds` per loop, and
ask and research counters keyed on the gather by name. The review loop and
the gather could not be reused, and the gather ran research and interview in
a fixed order. This ADR makes a flow a term built from small reusable flows,
under an algebra whose every rule is a law with a test. Design: #379;
implementation: PR #392.

Supersedes ADR 0018's blocks and its loop `rounds`. The rest of 0018 holds.

Superseded in part by ADR 0020: the word table, the gather and route
decisions, the `Choice` and `Route` laws, the `Par` ledger and the rejected
`choiceLoop` option. The flow core is now sums, cases and Elgot iteration.

## Decision

- **A flow is a term of `Flow i e o`.** In `i`, out `o`, and an optional
  exit `e`. The words:

  | Word | Meaning |
  |---|---|
  | `Do s` | one step |
  | `Id` | no step |
  | `f :> g` | series; an exit of either side exits the whole |
  | `inl`, `inr`, `f \|\|\| g` | sums and case |
  | `Catch f` | the codiagonal: the exit goes on as the out |
  | `Loop name f` | Elgot iteration: repeat until the body exits; no rounds |
  | `Capped limits atCap s` | a step whose `Meter` spends a budget |
  | `spawn limits atCap s` | `Capped`, for a step whose spend opens a child that must hand back |
  | `Choice name actions`, `choiceLoop` | the agent takes capped actions in any order, then `name.enough` |
  | `Route name branches` | the agent picks one named branch, once, by `name.branch` |
  | `Opt name skips f` | a Fuel may skip the body |
  | `Par name f` | one child run per item (the 10x fan-out) |
  | `Scope name f` | the body's states named `name/...` |

  `alternateLoop`, `choiceLoop` and `spawn` are functions, not constructors.
- **A flow library.** `State/Flow/Library.hs` holds `agree`, `gather`,
  `propose`, `build`, `review`, `describe` and `ship`. Engineer is
  `agree :> build :> review :> describe :> ship`; 10x reuses `agree`.
- **Budgets are step meters.** A step's `Meter` instance names its budget
  and says which outcome spends one. `Capped` gives the limit per Fuel as a
  `PerFuel Limit` and what happens at the cap: `Refuse` (take another
  outcome), `Stop` (`state stop rounds`) or `Extend` (the user says whether
  to go on). `graph` refuses a `Loop` whose body caps no step, so every loop
  terminates. The run keeps one meter ledger; caps count spends, so plan 3,
  CI 5 and a 10x's rounds 9 keep the old rounds minus one.
- **The gather is a choice.** One state, `gather`: spawn a researcher, ask a
  question, or `gather.enough`. A researcher's spawn and hand-back are
  `research.spawned` and `research.handed_back`, edges that stay at the
  state. `enough` waits for every open child: structured concurrency, an
  AND-join. At either cap the user says whether to `extend`.
- **A route is a pick.** One state, the hub, with one edge per branch,
  `name.branch`, into that branch; the branches share in, exit and out.
  `state next` there tells the agent to guess the branch from the request,
  say it, and ask the user once, `state ask --kind Pick`, only when the
  request is ambiguous. The hub is no loop: a route picked again sits in a
  `Loop`. Its picks decode by the fixed `routes` list beside `choices`.
- **The review is a loop with a final pick.** `review = Catch (Do Review :>
  fixReReview)`, with `fixReReview = Loop "fix" (Capped Re-reviews Refuse
  Pick :> Do Fix :> Do ReReview)`. `pick.loop` spends a re-review;
  `pick.final` and a clean review go on to describe, the final fixer.
- **Scoped names are the wire identity.** A step inside `Scope "s"` records
  `s/step.outcome`. A scope path is the free monoid on names. Engineer and
  10x use no scope, so their events are unchanged.
- **No global enums.** Loops, skips, fan-outs and choices are named by the
  term (`Name`), not by kernel-wide enums. The step layers stay typed.
- **Wire v4.** The review split and the gather events changed the log, so it
  is version 4; a version 3 log is refused.

## Laws

Each is a property test in `kernel/test/State/Category/LawsSpec.hs`, over
generated terms, unless noted.

| Law | Statement |
|---|---|
| identity | `Id :> f = f = f :> Id` |
| associativity | `(f :> g) :> h = f :> (g :> h)`; case is associative too |
| case beta, eta | `inl :> (f \|\|\| g) = f`, `inr :> (f \|\|\| g) = g`, `(inl :> h) \|\|\| (inr :> h) = h` |
| Catch | `Catch (f :> g) = f :> Catch g` for `f` with no exit; `Catch` distributes over a case |
| Elgot fixpoint | `Loop n f = Catch (f :> Loop n f)` |
| Scope | keeps the graph but its names; distributes over series; `Scope s . Scope t = Scope (s/t)` |
| Choice | the Kleene star of a sum: the order of the actions changes only the order they are shown in |
| Route | the order of the branches changes nothing a run walks; series distributes over it, `Route n [(b, f), (c, g)] :> h = Route n [(b, f :> h), (c, g :> h)]` (both up to bisimulation) |
| PerFuel monotone | each Fuel allows at least the spends and runs of the level below, in every named flow |

Type rules are compile errors, pinned by should-not-typecheck cases in
`FlowSpec` (capping a step with no meter, spawning a step that opens no
child). Graph rules are `Clash`es in `GraphSpec` (an unbounded loop, a
`Refuse` with no way out, a choice branch that is not a capped action, a
route's branch name twice).

## Consequences

- A new flow is a few library flows in a row; a new budget is a `Meter`
  instance and a `Capped`. No kernel enum changes.
- `state next` names the place, each option with its command and where it
  goes, and the budgets used and left, read from the ledger.
- The Fuel table's budget rows render from the terms, so the skills cannot
  drift from them (`kernel/rendered.nix`).
- Old logs (version 3) are refused, not migrated, as the user chose.
- `Par` keeps its own fan-out ledger beside the meters; merging the two is
  left for later.

## Considered options

- **The name `Circuit`.** Rejected by the user: `Flow` stays, a typed graph
  of steps, the word the skills, the ADRs and the log already use.
- **Encode exits as a sum in the out type (option C).** Rejected: every
  series would need a case to thread the exit, and `Loop` and `Catch` lose
  their plain Elgot and codiagonal laws. The exit stays its own index `e`.
- **Loops with rounds.** Rejected for step meters: a round count is a second
  budget beside each step's, special-cased per loop, and a choice has no
  back edge to count. A meter bounds a loop and a choice alike.
- **`choiceLoop` as `Loop` plus a pick step and a case.** Rejected: two
  events per action (pick, then act), a pick step per arity, more states.
