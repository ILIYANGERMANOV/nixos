# Vision

Read this before you design an agent feature. Paths are under
`programs/agents/`; a `State/...` path is under `kernel/src/`.

## North star

Agent loops that are reliable and do big work.

Yardstick: one request becomes an epic of N merged PRs, with no lost work and
no silent stalls.

## Design method

Category first. Encouraged, not mandatory.

1. Name the objects, the arrows and the laws (ADR 0018, ADR 0019).
2. Ask which properties those laws give.
3. Put each rule on the lowest rung of the logic ladder that can hold it.

The category concepts live in the kernel (`kernel/src/State/Category/`).
Agents use them through `state`.

## Properties

Draft list. They hold whatever model drives the flow. A cheaper model lowers
only the quality of the judgment steps, never these.

- **Bounded.** Every loop has a budget or a cap. Past it, the run ends or asks
  the user (`State/Category/Meter.hs`, law Bounded in `State/Run/Fold.hs`).
- **Resumable.** The run lives in its event log, not in an agent's context.
  An agent past its context budget hands back and a fresh agent starts from
  zero context, losing nothing (the context guard,
  `hooks/guards/context-guard/`; the 10x's `Resumed` and `Restarted` events in
  `State/Run/Event.hs`).
- **Lawful composition.** Flows are terms built from small flows, and every
  rule of the algebra is a law with a test (ADR 0019,
  `kernel/test/State/Category/LawsSpec.hs`).
- **Authority as code.** Who answers each kind of question is a table in the
  kernel (`State/Run/Ask.hs`), not a sentence in a prompt.
- **Nothing waits silently.** Every wait is named: `state next` prints
  `AWAIT` or `HANDBACK` (`State/Protocol/Advice.hs`), the stuck guard turns a
  repeat into a question, and the wait guard denies blind sleeps
  (`hooks/guards/wait-guard/`).
- **Replayable.** What a run knows is a pure fold over its log. Same log, same
  state (ADR 0014, `State/Run/Fold.hs`).

## How

```
kernel (pure Haskell) >> effect shell >> hooks >> prose
 decides                 git, files      sees the     judgment
 laws, tests             clock           moment       and taste
```

- Programs over prose (ADR 0013): a mechanical step becomes a program the
  agent calls.
- The logic ladder (`.claude/rules/agents-logic-ladder.md`): the kernel is the
  source of truth, hooks are thin adapters, prose only encourages.
- Today the hooks gate a lead's work until it runs `state init`, so every lead
  knows `state` and is pushed to use it (`State/Cli/Route.hs`). Harder
  enforcement is a goal for later, once general-purpose flows exist.

## Providers

- Claude is the main model today and stays so.
- Goal: any provider can drive a flow. The kernel and hooks are vendor-free;
  each agent tool is a thin backend (ADR 0011).
- Today's backend: `programs/claude-code`. Planned: OpenCode and Codex.

## Non-goals

Draft list.

- Not a framework for others. It serves this repository.
- Not removing judgment. Taste and judgment stay in prose.
- Encourage, not force. Agents are pushed toward `state`, not locked in.

ADRs (`docs/adr/`): 0011 agent compiler, 0013 programs over instructions,
0014 pure fold over events, 0018 category model, 0019 composable flows.
