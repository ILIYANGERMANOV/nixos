# The flow core: sums, cases, Elgot-shaped loops and step meters

A flow is a term built from a small core, and everything else is a library
function over it. A new flow is a few blocks in a row; a new budget is a
meter on a step. No kernel enum changes, and every rule of the core is a
law with a test. ADR 0018 is the model; ADR 0021 adds effects.

```haskell
engineer = Handle PickHandler
  (Do Fuel :> agree :> build :> review :> describe :> ship)
review   = Catch (Do Review :> fixReReview)
fixReReview =
  Loop "fix" (Capped (UpTo <$> PerFuel 1 3 5) Refuse (Step PickRows)
                :> Do Fix :> Do ReReview)
```

## Decision

- **The core.** `Flow s i e o` (`State/Category/Flow.hs`): `s` the
  structure (`Shape`), in `i`, an optional exit `e`, out `o`. These
  constructors and no others:

  | Word | Meaning |
  |---|---|
  | `Do s` | one step |
  | `Id` | no step |
  | `Into` | retype as `Result`: no step, no event |
  | `f :> g` | series; an exit of either side exits the whole |
  | `Case bs` | copairing: one branch per label of a `Sum`, in its order |
  | `Exit` | leave to the innermost `Catch` or `Loop` |
  | `Catch f` | the codiagonal: the exit goes on as the out |
  | `Loop name f` | repeat until the body exits: the shape of Elgot iteration |
  | `Capped limits atCap c` | a step, or a `Fork` of one, whose `Meter` spends a budget |
  | `Fork g f` | start `f` as a child in the typed group `g`, go on with the input |
  | `Await g` | wait for every open child of `g`'s role: their results, in fork order |
  | `Each f` | `f` once per item of a list, in this run |
  | `Scope name f` | the body's states named `name/...` |
  | `Handle h f` | `h` answers one effect `f` raises; drawn as `f` (ADR 0021) |

- **Sums are labelled.** `Ty` has `Sum [(Symbol, Ty)]`. A step into a sum
  has one outcome per label; the label is its event name. `Case` takes
  branches indexed by the label list, so a missing or mislabelled branch is
  a compile error. An uncaught `Exit` is a compile error too.
- **The library builds the rest.** `State/Flow/Combinator.hs`:

  | Function | Term |
  |---|---|
  | `choice name bs` | `Do (Pick name) :> Case bs` |
  | `choiceLoop name enough actions` | `Loop name (choice name (enough :> Exit, actions...))` |
  | `skippable step skips`, `skippableBlock name skips f` | `Do (Skip name skips) :> Case (skip: Id, run: f)` |
  | `parallel g f` | `Each (Fork g f) :> Await g` |
  | `upTo n atCap c` | `Capped` with the same limit at every Fuel |

  `State/Flow/Block.hs` holds the blocks the named flows compose: `agree`,
  `gather`, `research`, `researchLoop`, `discuss`, `propose`, `build`,
  `review`, `describe` and `ship`.
- **Budgets are step meters.** A step's `Meter` instance
  (`State/Category/Meter.hs`) names its budget and says which outcome or
  question spends one. `Capped` gives the limit per Fuel as a
  `PerFuel Limit` and what happens at the cap (`AtCap`):

  | `AtCap` | At the cap |
  |---|---|
  | `Refuse` | the spend is refused; the agent takes another outcome |
  | `Stop` | the run stops (`state stop rounds`) unless it takes another outcome |
  | `Extend` | the user is asked whether to go on; `extend` grants the budget again |

  A step with no `Meter` cannot be capped (a compile error). `graph`
  refuses a `Loop` whose body caps no step, so every loop is bounded.
- **A pick and its action are two steps, two events.** The agent records
  the pick, `gather.research`, then the action's own event,
  `gather/research.spawned`. The fold, the advice and the graph need no
  special case.
- **The gather is a `choiceLoop`.** Its actions are `research`, a capped
  `Fork` of the researcher into the `researchers` group, and `interview`.
  `enough` is `Await` of the group, then `notes.done`, then `Exit`. The
  architect's `exploring` and `discussing` are the same shape.
- **Hub rules are steps.** Every role's flow opens with `Do Fuel`: the
  level is the event `fuel.set <level>`. The chief's request is `Do Fuel`
  then `choice "route"`. The fold has no rule keyed by a state's name.
- **Optional blocks are `skippable`.** A `skip_<block>` state, its events
  `skip_<block>.skip` and `skip_<block>.run`. The run's Fuel says when
  `skip` is taken.
- **The review is a loop with a final pick.** `pick.loop` spends a
  re-review; `pick.final` and a clean review go on to describe.
- **The 10x's engineers are `parallel`.** Each engineer is spawned once
  its task's dependencies merged; `merge` gets the PRs in fork order.
- **A fork must be awaited.** The graph refuses a `Fork` with any way out
  that passes no `Await` of its group (`NotAwaited`), and one state name
  drawn twice (`SameState`).
- **One ledger of open children**, keyed by a `ChildId` sum: a span id
  for a subagent, a run id for a 10x engineer run. A subagent's entry
  opens at its `span_started` and closes at its `span_ended`. Meters only
  count spends.
- **Scoped names are the wire identity.** A step inside `Scope "s"`
  records `s/step.outcome`. A scope path is the free monoid on names.
- **No global enums.** Loops, skips, groups and choices are named by the
  term (`Name`). The step layers stay typed.
- **Wire version 4** (`State/Run/Codec.hs`). A log with an older version or
  a removed event is refused, not migrated.

## Laws

The laws and their tests: [CATEGORY-THEORY, Flow](../harness/CATEGORY-THEORY.md#flow)
and [Fuel](../harness/CATEGORY-THEORY.md#fuel).

Not claimed: `Loop` has the shape of Elgot iteration and its fixpoint law
is tested, but naturality, codiagonal and uniformity are not. `Case` is
copairing with beta and fusion tested; eta cannot be written.

Type rules are should-not-typecheck cases in `FlowSpec` (a missing or
mislabelled `Case` branch, an uncaught `Exit`, capping a step with no
meter). Graph rules are `Clash`es in `GraphSpec` (`NotAwaited`,
`SameState`, an unbounded loop, a `Refuse` with no way out).

## Considered options

- **Special blocks beside the core** (`Choice`, `Route`, `Opt`, `Par` as
  constructors, with hidden hub and fork steps). Rejected: each needed its
  own graph part, laws and fold rules. As library functions they inherit
  `Case`'s and `Loop`'s laws.
- **Loops with rounds.** Rejected for step meters: a round count is a
  second budget beside each step's, special-cased per loop, and a choice
  has no back edge to count. A meter bounds a loop and a choice alike.
- **Encode exits as a sum in the out type.** Rejected: every series would
  need a case to thread the exit, and `Loop` and `Catch` lose their plain
  laws. The exit stays its own index `e`.
- **Binary sums (`inl`, `inr`, `|||`).** Rejected: an n-way branch nests
  them, and the nesting is not the domain's. A labelled n-ary `Sum` names
  each branch by its event.
- **Drop `Into`; end each chief branch in a step returning `Result`.**
  Rejected: one more event per request for a retype no one records.
- **A class for what `Capped` takes.** Rejected for a closed GADT: a step
  or a `Fork` of one, the only two cases.
- **The name `Circuit`.** Rejected by the user: `Flow` stays.

## Consequences

- One generic graph part per constructor.
- `state next` names the place, each option with its command and where it
  goes, and the budgets used and left.
- The skills' states and Fuel tables render from the terms, so the skills
  cannot drift from them (`kernel/rendered.nix`).

## History

- #379, #392: flows compose from small lawful flows; step meters.
- #457, #462: the core from sums, cases and Elgot iteration.
- #478: inline handlers, plain names, `upTo`.
- #552: [ADR 0023](0023-append-only-event-store-with-rebuilt-projections.md)
  replaces wire version 4 with a `schema_version` per event type. No log
  is refused for its age.
- #577: the ledger keys a subagent by its span. `worker_spawned` and
  `worker_returned` are gone: no kernel writes them since spans, and only
  new runs matter, so a log that holds one no longer decodes.
