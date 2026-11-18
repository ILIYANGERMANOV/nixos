# Flow effects: Pick, Ask and Focus in a flow's type

ADR 0020 left a flow's needs from outside implicit: an agent's pick, a
question to the user and (planned) a wait for the user's attention were
special cases in the fold and the advice, and nothing in a flow's type said
which a run would meet or who answers them. This ADR makes them first-order
effects of the term. Design: #461 (slice S2); implementation: PR #470.

## Decision

- **Blocks and effects.** A block is what the flow does: a step and the
  ADR 0020 core around it. An effect is what a run needs from outside the
  flow to go on: `type data Eff = PickE | AskE | FocusE` in
  `State/Category/Effect.hs`. Pick: the agent picks a branch. Ask: a
  question goes to the user. Focus: the run waits for the user's
  attention (the chief's requests raise it; see S4 below).
- **The type index holds the structure.** `Flow s i e o` carries a
  `Shape` `s`, a `type data` with one constructor per `Flow` constructor
  (`DoS s`, `:>>`, `LoopS`, `CaseS`, ...). Named flows give theirs an alias
  (`EngineerS`, `ArchitectS`, ...).
- **An effect is read off a step's type, not a node.** Each step layer
  states `Raises s :: [Eff]` (`State/Category/Step.hs`), its effects
  beyond a question: most `'[]`, a pick `'[PickE]`. `Effects s` collects
  them from the shape: `DoS s` raises `AskE` (every step may put a
  question, stated once) and `Raises s`, every other shape the union of its children's, a forked child's included. There is
  no `Perform` constructor, so `choice = Do (Pick n) :> Case bs` stays and
  graphs, states tables, the catalog and the advice do not change.
- **`Handle` takes one effect off.** `Handle :: Handler eff -> Flow s i e o
  -> Flow (HandleS eff s) i e o`, with `Handler` a closed GADT naming who
  answers: `AgentPicks`, `PrincipalAnswers`, `FocusHere`. It is drawn as
  its body. A named flow is `Handle AgentPicks (...)`: its Ask
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
  `type data Effs = Flags Bool Bool Bool`, one flag per `Eff`; a union is
  three `||`s, and `Effects s = ToList (EffectSet s)` reads the list off.

## S3: Ask bubbles up

#461 slice S3 (PR #474) makes a nested flow's question the enclosing
flow's, as an unhandled operation goes to the enclosing handler:

- **Ask is handled once, at the root.** `Handle AgentPicks` takes Pick only, so
  every named flow's `Effects` keep `AskE`, and a flow nested in another
  (a 10x's forked engineer, a chief's branch) raises its questions to it.
  The role registry (`State.Role`) is the one root: each
  flow sits under `Handle PrincipalAnswers`, under which `Unhandled (Effects s) ~ '[]`
  holds.
- **The handler is the principal, decided at runtime.** The same term
  roots a user's run and a linked child's, so the term cannot say who
  answers; `PrincipalAnswers` means the run's `Principal`, which
  `Ask.deliver` already reads: the user for a run of their own, the parent
  run for a linked child.
- **A parent link is a sum.** `Parent {run, link}`, `data Link = AtFan
  TaskId | Direct`: a fan-out's child takes one of its tasks; a direct
  child (`state init --parent <run>`, no `--task`) is linked to a parent at
  no fan-out, the chief delegating one engineer. Its question reaches the
  parent's log as `Asked (ChildRun child)`; the parent rules or forwards
  it, and the answer goes down to that child only.

## S4: the Focus handler

#461 slice S4 gives `FocusE` its handler, `FocusHere`, on the chief:

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
  traced log (node, decisions, open questions, last worker, paused-at);
  nothing is stored for them.
- **Advice from logged times.** `resumeAdvice` is pure over the pause and
  now: `resume agent <id>` under `cacheLife - safetyBuffer` (300s - 15s,
  the user's buffer), else `fresh agent from card`. `state focus rK` takes
  both times from the log's `ts`, so a replay advises the same; `state
  tasks` takes now from the clock.

## Laws

| Law | Where |
|---|---|
| a handler draws as the flow it handles | `LawsSpec` |
| live appends reach the run the log replays | `FoldSpec` |
| replaying a prefix then the rest is replaying the whole | `FoldSpec` |
| a perturbed event is refused (a pick off its choice, an answer to no question) | `FoldSpec` |
| `Effects` of each registered flow, and of a handled `parallel`, is the stated list; each root's is `'[]` | `RoleSpec` (`:~:`) |
| ruling one direct child's question changes no other child's log | `MainSpec` |
| a whole flow with an unhandled Pick, Ask or Focus does not compile | `FlowSpec` |
| turning away from a request and back lands where the log without the turn does | `FoldSpec` |
| resume advice turns at exactly `cacheLife - safetyBuffer`, on any seed | `CardSpec` |

## Consequences

- Adding an effect is a constructor of `Eff`, a flag in `Effs`, a
  `Handler` constructor and its arm in `Fold.handle`; the compiler names
  the rest.
- A step that raises a new effect says so in its layer's `Raises`; every
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
