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
  attention (no flow raises it yet; #461 S4 places it).
- **The type index holds the structure.** `Flow s i e o` carries a
  `Shape` `s`, a `type data` with one constructor per `Flow` constructor
  (`DoS s`, `:>>`, `LoopS`, `CaseS`, ...). Named flows give theirs an alias
  (`EngineerS`, `ArchitectS`, ...).
- **An effect is read off a step's type, not a node.** Each step layer
  states `Raises s :: [Eff]` (`State/Category/Step.hs`): every step may put
  a question (`'[AskE]`), a pick also picks (`'[PickE, AskE]`). `Effects s`
  collects them from the shape: `DoS s` raises `Raises s`, every other
  shape the union of its children's, a forked child's included. There is
  no `Perform` constructor, so `choice = Do (Pick n) :> Case bs` stays and
  graphs, states tables, the catalog and the advice do not change.
- **`Handle` takes one effect off.** `Handle :: Handler eff -> Flow s i e o
  -> Flow (HandleS eff s) i e o`, with `Handler` a closed GADT naming who
  answers: `AgentPicks`, `UserAsks`, `FocusHere`. It is drawn as its body.
  A named flow is `handled (...)`, `Handle AgentPicks . Handle UserAsks`.
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

## Laws

| Law | Where |
|---|---|
| a handler draws as the flow it handles | `LawsSpec` |
| live appends reach the run the log replays | `FoldSpec` |
| replaying a prefix then the rest is replaying the whole | `FoldSpec` |
| a perturbed event is refused (a pick off its choice, an answer to no question) | `FoldSpec` |
| `Effects` of each registered flow, and of a handled `par`, is the stated list | `RoleSpec` (`:~:`) |
| a whole flow with an unhandled Pick, Ask or Focus does not compile | `FlowSpec` |

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
