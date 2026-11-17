# The flow core from sums, cases and Elgot iteration

ADR 0019 made a flow a term, but kept special building blocks beside the
category: `Choice` and `Route` (hidden hub and fork steps, a fixed `choices`
and `routes` registry), `Opt` (a skip arrow), `Par` (its own fan-out), binary
sums (`inl`, `inr`, `|||`) and hub rules keyed by name in the fold
(`FuelSetOnce`, `TargetOffHub`, `PickedOnce`). Each needed its own graph
part, its own laws and its own case in every consumer. Part of the reason
was log and graph compatibility, which no longer counts
(`.claude/rules/agents-kernel.md`). This ADR keeps only a small core and
builds the rest as library functions. Design: #457; implementation: PR #462.

Supersedes ADR 0019's word table, its gather and route decisions, its
`Choice` and `Route` laws, its `Par` ledger note and its rejected option
"`choiceLoop` as `Loop` plus a pick step and a case". The rest of 0019 holds:
meters, `Capped`, `Loop` without rounds, the review loop, scoped names.

## Decision

- **The core.** `Flow i e o` has these constructors and no others:

  | Word | Meaning |
  |---|---|
  | `Do s` | one step |
  | `Id` | no step |
  | `Into` | retype as `Result`: the terminal map, no step, no event |
  | `f :> g` | series; an exit of either side exits the whole |
  | `Case bs` | copairing: one branch per label of a `Sum`, in its order |
  | `Exit` | leave to the innermost `Catch` or `Loop` |
  | `Catch f` | the codiagonal: the exit goes on as the out |
  | `Loop name f` | Elgot iteration: repeat until the body exits |
  | `Capped limits atCap c` | a step, or a `Fork` of one, whose `Meter` spends a budget |
  | `Fork g f` | start `f` as a child in the typed group `g`, go on with the input |
  | `Await g` | wait for every child of `g`: their results, in fork order |
  | `Each f` | `f` once per item of a list, in this run |
  | `Scope name f` | the body's states named `name/...` |

- **Sums are labelled.** `Ty` has `Sum [(Symbol, Ty)]`. A step into a sum
  has one outcome per label, on a `Took "<label>"` leg; the label is its
  event name. `Case` takes branches indexed by the label list, so a missing
  or mislabelled branch is a compile error. An uncaught `Exit` leaves the
  whole flow's exit type not `Nothing`, a compile error too.
- **The library builds the rest.** In `State/Flow/Library.hs`:

  | Function | Term |
  |---|---|
  | `choice name bs` | `Do (Pick name) :> Case bs` |
  | `choiceLoop name enough actions` | `Loop name (choice name (enough :> Exit, actions...))` |
  | `opt name skips f` | `Do (Skip name skips) :> Case (skip: Id, run: f)` |
  | `par g f` | `Each (Fork g f) :> Await g` |

- **A pick and its action are two steps, two events.** The agent records
  the pick, `gather.research`, then the action's own event,
  `gather/research.spawned`. No replay merge, no CLI shortcut.
- **The gather is a `choiceLoop`.** Its actions are `research`, a capped
  `Fork` of the researcher into the `researchers` group, and `interview`
  (`interview.asked`), each its own state. `enough` is `Await` of the
  group, which goes on by itself once every researcher handed back, then
  `Notes` (`notes.done`) merges their hand-backs, then `Exit`. The
  architect's `exploring` and `discussing` are the same shape.
- **Hub rules are steps.** Every role's flow opens with `Do Fuel`: the
  level is the event `fuel.set <level>`, given by the caller or asked once.
  A target is named only at a Fuel state. The chief's request is `Do Fuel`
  then `choice "route"`; its block route is `choice "block"`. The fold has
  no rule keyed by a state's name.
- **Optional blocks are `opt`.** A `skip_<block>` state, its events
  `skip_<block>.skip` and `skip_<block>.run`. The run's Fuel says when a
  level takes `skip`; render reads the skippable blocks from the `Skip`
  steps.
- **The 10x's engineers are `par`.** `spawn_engineers` is the fork and
  passes at once; each engineer is spawned at `engineers`, the await, once
  its task's dependencies merged. The await goes on to `merge` by itself on
  the event that settles the last task; `merge` gets the PRs in fork order.
- **A fork must be awaited.** The graph refuses a `Fork` with any way out,
  an `Exit` or a loop's exit included, that passes no `Await` of its group
  (`NotAwaited`), and one state name drawn twice (`SameState`).
- **The review's pick step is `PickRows` in Haskell.** Its state and
  events stay `pick`, `pick.final`, `pick.loop`.

## Laws

Each is a property test in `kernel/test/State/Category/LawsSpec.hs` unless
noted. They replace 0019's `case beta, eta`, `Choice` and `Route` rows.

| Law | Statement |
|---|---|
| case beta | a step into a sum, its edge `l` walks as branch `l` |
| case fusion | `Case bs :> h = Case (each b, b :> h)` |
| case eta | not stated as a term: the core has no injection, and a flow out of a sum is already a `Case` (`Do` takes no sum) |
| case order | the order of a choice's branches changes nothing a run walks |
| Catch | `Catch (f :> g) = f :> Catch g` for `f` with no exit; `Catch` distributes over a case; `Catch Exit = Id` |
| Elgot fixpoint | `Loop n f = Catch (f :> Loop n f)`; a `choiceLoop` walks as its choice unrolled once |
| choiceLoop | the Kleene star of a sum: the order of the actions changes nothing a run walks |
| par identity, composition | `par g Id`, `par g f` and `par g (f :> h)` draw one parent graph; `Merge` gets the results in fork order (`AdviceSpec`) |

Type rules are should-not-typecheck cases in `FlowSpec` (a missing or
mislabelled `Case` branch, an uncaught `Exit`, capping a step with no
meter). Graph rules are `Clash`es in `GraphSpec` (`NotAwaited`, `SameState`,
an unbounded loop).

## Consequences

- One generic graph part per constructor; `choicePart`, `routePart`, the
  fan-out part, the hidden hub and fork steps and their registries are gone.
- States and events changed: `fuel` is a state (`fuel.set`, was the event
  `fuel`); the gather adds `gather/research`, `gather/researchers`,
  `gather/notes` and `interview` (`gather.research`, `gather.interview`,
  `interview.asked`, `gather/notes.done`), as do `exploring` and
  `discussing` (`discuss.asked`); `skip_simplify_plan` and `skip_refactor`
  replace the `skipped` events of `simplify_plan`, `refactor` and
  `simplify_pr`; `spawn_engineers` is new and `engineers.done` is gone. The
  skills' states tables render from the terms (`kernel/rendered.nix`).
- The wire stays version 4; a log with a removed event is refused, not
  migrated.
- The open children are still counted in two places, the meters' spends
  and the 10x fan ledger; one ledger keyed by a `ChildId` sum (an agent id
  for an agent child, a run id for a 10x engineer run) is the decided
  follow-up.

## Considered options

- **Keep `Choice` and `Route` as constructors.** Rejected: each is a pick
  plus a case, with its own graph part, laws and fold rules. As library
  functions they inherit `Case`'s and `Loop`'s laws.
- **`choiceLoop` as `Loop` plus a pick step and a case.** Rejected in 0019
  for its two events per action and its extra states; taken now. Two events
  make the pick and the action each a plain step, so the fold, the advice
  and the graph need no special case, and a pick per arity is one `Pick`
  step indexed by its labels.
- **Binary sums (`inl`, `inr`, `|||`).** Rejected: an n-way branch nests
  them, and the nesting is not the domain's. A labelled n-ary `Sum` names
  each branch by its event.
- **Drop `Into`; end each chief branch in a step returning `Result`.**
  Rejected: one more event per request for a retype no one records.
- **A class for what `Capped` takes.** Rejected for a closed GADT: a step
  or a `Fork` of one, the only two cases.
