# Vision

Read before any agent design. Paths are under `programs/agents/`, a
`State/...` path under `kernel/src/`, ADRs under `docs/adr/`.

## North star

Agent loops that are reliable and do big work.

Yardstick: one request becomes an epic of N merged PRs, with no lost work and
no silent stalls.

## Design method

Category first. Encouraged, not mandatory.

1. Name the objects, the arrows and the laws (ADR 0018, ADR 0019).
2. Ask which properties those laws give.
3. Put each rule on the first rung of the logic ladder that can hold it.

The concepts live in `State/Category/`; agents use them through `state`.

## Properties (draft)

They hold whatever model drives the flow. Today a cheaper model lowers only
the quality of the judgment steps, never these; Direction's end goal closes
that gap.

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
  knows `state` and is pushed to use it (`State/Cli/Route.hs`).

## Direction

Rule of thumb: the more agents run on `state` and the kernel, the more
deterministic the flows.

- Today: fixed flows, and that is good. `/engineer` and `/10x` do their jobs
  well (`State/Flow/Engineer.hs`, `State/Flow/TenX.hs`).
- Next: a general-purpose chief flow that can do more.
- Then: a library of flows, one per use case that proved itself. Agents choose
  between flows and compose them to do arbitrary tasks.
- `state` is expected, not enforced: hooks gate the start, not every action.
  Harder enforcement comes once general-purpose flows exist.
- End goal: a cheap, fast model drives the flows and reaches the quality of a
  top model, because each flow hands it very small jobs in the right order.

## Providers

- Claude is the main model today and stays so.
- Goal: any provider can drive a flow. The kernel and hooks are vendor-free;
  each agent tool is a thin backend (ADR 0011).
- Today's backend: Claude Code (`../claude-code`). Planned: OpenCode and Codex.

## Non-goals (draft)

- Not a framework for others. It serves this repository.
- Not removing judgment. Taste and judgment stay in prose.
- Encourage, not force. Agents are pushed toward `state`, not locked in.
