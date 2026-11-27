# Flow effects: Pick, Ask, Focus and Await in a flow's type

ADR 0020 left a flow's needs from outside implicit: an agent's pick, a
question to the user and (planned) a wait for the user's attention were
special cases in the fold and the advice, and nothing in a flow's type said
which a run would meet or who answers them. This ADR makes them first-order
effects of the term. Design: #461 (slice S2); implementation: PR #470.

## Decision

- **Blocks and effects.** A block is what the flow does: a step and the
  ADR 0020 core around it. An effect is what a run needs from outside the
  flow to go on: `type data Eff = PickE | AskE | FocusE | AwaitE` in
  `State/Category/Effect.hs`. Pick: the agent picks a branch. Ask: a
  question goes to the user. Focus: the run waits for the user's
  attention (the chief's requests raise it; see S4 below). Await: the run
  waits on a PR's CI or merge (see "Operations" below).
- **The type index holds the structure.** `Flow s i e o` carries a
  `Shape` `s`, a `type data` with one constructor per `Flow` constructor
  (`DoS s`, `:>>`, `LoopS`, `CaseS`, ...). Named flows give theirs an alias
  (`EngineerS`, `ArchitectS`, ...).
- **An effect is read off a step's type, not a node.** Each step layer
  states `Raises s :: [Op]` (`State/Category/Step.hs`), its operations
  beyond a question, each of one effect (see "Operations" below): most
  `'[]`, a pick `'[ 'Picks]`. `Effects s` collects
  them from the shape: `DoS s` raises `AskE` (every step may put a
  question, stated once) and `Raises s`, every other shape the union of its children's, a forked child's included. There is
  no `Perform` constructor, so `choice = Do (Pick n) :> Case bs` stays and
  graphs, states tables, the catalog and the advice do not change.
- **`Handle` takes one effect off.** `Handle :: Handler eff -> Flow s i e o
  -> Flow (HandleS eff s) i e o`, with `Handler` a closed GADT naming who
  answers, named after its effect: `PickHandler`, `AskHandler`,
  `FocusHandler`, `AwaitHandler`. It is drawn as
  its body. A named flow is `Handle PickHandler (...)`: its Ask
  stays open (see S3 below).
- **A whole flow handles every effect.** `SomeFlow` demands
  `Unhandled (Effects s) ~ '[]`; a flow that leaves one does not compile
  and names it: `A whole flow leaves effects unhandled: '[PickE]`.
- **One pure handler per effect, for live and replay.** `Fold.handle ::
  Handler eff -> OpenGraph -> RunState -> Answering eff -> Either Refusal
  RunState`. Live turns a command into an event and appends it through
  `Fold.appendTo`, the same pure fold a replay runs, so both reach the same
  handler: no live/replay mode, and a mismatch is a `Refusal`, as before.
- **`Effects` is a flag set.** `EffectSet s :: Effs`, with
  `type data Effs = Flags Bool Bool Bool Bool`, one flag per `Eff`; a union is
  four `||`s, and `Effects s = ToList (EffectSet s)` reads the list off.
- **Flows are graded by their effects.** `Id` raises none, `:>` takes the
  union, and `Handle` removes the effect it handles: a grading by the
  monoid (effect sets, union, empty). This describes the types; it is not
  a tested law.

## S3: Ask bubbles up

#461 slice S3 (PR #474) makes a nested flow's question the enclosing
flow's, as an unhandled operation goes to the enclosing handler:

- **Ask is handled once, at the root.** `Handle PickHandler` takes Pick only, so
  every named flow's `Effects` keep `AskE`, and a flow nested in another
  (a 10x's forked engineer, a chief's branch) raises its questions to it.
  The role registry (`State.Role`) is the one root: each
  flow sits under `Handle AskHandler`, under which `Unhandled (Effects s) ~ '[]`
  holds.
- **The handler is the principal, decided at runtime.** The same term
  roots a user's run and a linked child's, so the term cannot say who
  answers; `AskHandler` means the run's `Principal`, which
  `Ask.deliver` already reads: the user for a run of their own, the parent
  run for a linked child.
- **A parent link is a sum.** `Parent {run, link}`, `data Link = InFan
  ChildTask | Direct` (`State/Run/Ask.hs`): a fan-out's child takes one of
  its tasks, or the request the chief handed on whole; a direct
  child (`state init --parent <run>`, no `--task`) is linked to a parent at
  no fan-out, the chief delegating one engineer. Its question reaches the
  parent's log as `Asked (ChildRun child)`; the parent rules or forwards
  it, and the answer goes down to that child only.

## S4: the Focus handler

#461 slice S4 gives `FocusE` its handler, `FocusHandler`, on the chief:

- **A zipper of saved positions.** A chief request is a task (`r1`,
  `r2`, ...). `RunState` holds the one in focus and a map of the waiting
  ones, each saved as its position (`at`, `rounds`): a defunctionalised
  continuation (Reynolds 1972), a label plus live locals, as Kotlin does.
- **Two events, one command.** `Suspended TaskNo OneLine` (where it stands)
  and `Focused TaskNo`, from `state focus [rK] --summary <line>`: the
  focus waits and the target, or a new request at `fuel`, takes it. A
  request with nothing recorded is dropped, not suspended; one at `next`
  is finished, read off its cursor: the turn records `next.request`. Its forwarded
  questions are parked (S3's `QuestionParked`) and stay answerable.
- **Cards are derived.** `Card.cards` reads each request's card off the
  traced log (node, decisions, open questions, paused-at); nothing is
  stored for them. `state focus rK` counts the pause from the log's `ts`,
  so a replay prints the same; `state tasks` takes now from the clock.

## Operations replace `Special`

PR #541 drops `Special`, a closed per-step tag (`Ordinary`, `AsksConfirm`,
`AwaitsCi`, `AwaitsMerge`, `TellsResult`, `Discusses`) that generic code
read outside the flow algebra. A step's needs now live in its type alone:

- **An operation per need.** `data OpOf text = Picks | Focuses | Confirms
  text | Discusses | Awaits Waiting`, one declaration at two levels like
  `TyOf`: `Op = OpOf Symbol` in a step's `Raises`, `OpVal = OpOf Text`
  what the advice and the fold match on (`KnownOps`, `opsOf`). `EffOf`
  maps each to its effect: a Confirm or a Discuss is an Ask, so no new
  handler; an Await is the new `AwaitE`. `Effs` stays a flag set: an
  operation reduces to its flag at the step, so no `Symbol` travels
  through a `Shape`.
- **Await is handled at the root.** The engineer, the 10x and the chief
  ship PRs, so their roots add `Handle AwaitHandler`; the architect needs
  none. Its handler is real: `applyEvent` routes the outcome of a step
  that awaits (`Settles`) to it before the generic step arm, and it moves
  the run as any outcome does. No event changes. `TaskMoved` is not the
  wait's answer, as it arrives for any task while a fan-out is open.
- **The last result is derived.** `TellsResult` is gone: a step whose input
  is `Result` names the url the run recorded last.
- **A lost guarantee.** `Raises` is a list, so a step could raise two entry
  operations (`Confirms`, `Discusses`, `Awaits`) where `Special` allowed
  one. None does; the advice takes the first. A type-level guard would
  cost more than it saves.

## Laws

| Law | Where |
|---|---|
| a handler draws as the flow it handles | `LawsSpec` |
| live appends reach the run the log replays | `FoldSpec` |
| replaying a prefix then the rest is replaying the whole | `FoldSpec` |
| a perturbed event is refused (a pick off its choice, an answer to no question) | `FoldSpec` |
| `Effects` of each registered flow, and of a handled `parallel`, is the stated list; each root's is `'[]` | `RoleSpec` (`:~:`) |
| ruling one direct child's question changes no other child's log | `MainSpec` |
| a whole flow with an unhandled Pick, Ask, Focus or Await does not compile | `FlowSpec` |
| turning away from a request and back lands where the log without the turn does | `FoldSpec` |

## Consequences

- Adding an effect is a constructor of `Eff`, a flag in `Effs`, a
  `Handler` constructor and its arm in `Fold.handle`; the compiler names
  the rest.
- A step that raises a new operation says so in its layer's `Raises`; every
  flow using it fails to compile until a `Handle` takes it.
- States tables, graphs and the event log are unchanged by this ADR.

## Considered options

- **A `Perform` constructor per effect.** Rejected: Pick already is the
  `PickStep` layer, and a node would add a graph part, a catalog entry and
  a fold arm for what a step's type already says.
- **A `Live`/`Replay` source sum with a handler per mode.** Rejected: live
  already appends events through the replay fold, so one handler serves
  both.
- **`Effects` as a type-level list union by `If` and `Elem`.** Rejected:
  GHC's coercions grew with the whole flow's `Shape`, and `State.Role`,
  where `SomeFlow` reduces `Effects` of whole flows, ran past 8.8G of heap
  (`-M8g` overflow). The flag set builds the library in 24s at 0.6G.
- **`Raises` as a closed type family.** Rejected: a closed family names
  every layer in one place, but the pick and Fuel layers import
  `State.Category.Flow`, which reads `Raises`, so that place cannot import
  them back. It stays an associated family, as `Sig` is: one equation per
  layer instance, which a layer cannot leave out.

## History

- #459, #461, #468, #470, #474: effects in a flow's type; Ask bubbles up;
  the Focus handler.
- #478: inline handlers.
- #541: operations replace `Special`; the Await handler.
- #577: the card's "resume agent" advice is gone. It named the last
  agent a `worker_spawned` line bound, and no kernel writes that line
  since spans: the advice could never fire for a new run. Only new runs
  matter, so no reader is kept for old logs.
