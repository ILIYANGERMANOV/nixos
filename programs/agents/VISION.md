# Vision

Read before any agent design. Paths are under `programs/agents/`, a
`State/...` path under `kernel/src/`, ADRs under `docs/adr/`. How it all
works today: [`docs/harness/`](../../docs/harness/README.md).

## What kategory is

A harness-wrapper: it wraps an agent harness, Claude Code today, and runs
each flow as a state machine. The pitch, owned there:
[`docs/harness/README.md`](../../docs/harness/README.md#what-kategory-is).

## North star

Agent loops that are reliable and do big work.

Yardstick: one request becomes an epic of N merged PRs, with no lost work and
no silent stalls.

## Principles

- **Lean subagents.** Each subagent does one small, focused task with a
  small context. Small contexts are fast and cheap, and they leave less
  room for mistakes.
- **Separation of concerns.** The kernel decides, hooks see the moment,
  prose holds judgment. Each rule lives in one place.
- **Single responsibility.** One role, one job: a researcher finds facts,
  an implementer builds one slice, a reviewer reviews. A lead plans and
  orchestrates; its workers do the focused work.
- **Programs over prose** (ADR 0013): a mechanical step becomes a program
  the agent calls.

## Design method

Category first. Encouraged, not mandatory.

1. Name the objects, the arrows and the laws (ADR 0018, ADR 0020,
   ADR 0021).
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
  rule of the algebra is a law with a test (ADR 0020,
  `kernel/test/State/Category/LawsSpec.hs`).
- **Authority as code.** Who answers each kind of question is a table in the
  kernel (`State/Run/Ask.hs`), not a sentence in a prompt.
- **Nothing waits silently.** Every wait is named: `state next` prints
  `AWAIT` or `HANDBACK` (`State/Protocol/Advice.hs`), the kernel's stuck rule
  turns the same problems two rounds in a row into a question
  (`State/Run/Fold.hs`), and the wait guard denies blind sleeps
  (`hooks/guards/wait-guard/`).
- **Replayable.** What a run knows is a pure fold over its log. Same log, same
  state (ADR 0014, `State/Run/Fold.hs`).

## How

- The reliability pyramid
  ([`docs/harness/README.md`](../../docs/harness/README.md)): the logic
  ladder's four rungs, pure kernel, effect shell, hooks and prose. Each rung
  up is more deterministic and more testable.
- Above the ladder sits each project's own CI (`just check`, tests, lint):
  the last gate, outside the harness.
- The logic ladder (`.claude/rules/agents-logic-ladder.md`): the kernel is
  the source of truth, hooks are thin adapters, prose only encourages.
- Today the hooks gate a lead's work until it runs `state init`, so every
  lead knows `state` and is pushed to use it (`State/Cli/Route.hs`).

## Direction

Rule of thumb: the more agents run on `state` and the kernel, the more
deterministic the flows.

- Today: fixed flows, and that is good. `/engineer`, `/10x-engineer` and
  `/architect` do their jobs well (`State/Flow/Role/Engineer.hs`,
  `State/Flow/Role/TenX.hs`, `State/Flow/Role/Architect.hs`) and stay fixed.
- `/engineer` is the recommended entry for one task. The general-purpose
  chief flow (`State/Flow/Role/Chief.hs`) routes many requests: each to a
  flow, a block, a discussion or a direct fix.
- Then: a library of flows, one per use case that proved itself. Agents choose
  between flows and compose them to do arbitrary tasks.
- End goal: a cheap, fast model drives the flows and reaches the quality of a
  top model, because each flow hands it very small jobs in the right order.

## Providers

- Claude is the main model today and stays so.
- Goal: any provider can drive a flow. The kernel and hooks are vendor-free;
  each agent tool is a thin backend (ADR 0011).
- Today's backends: Claude Code (`../claude-code`) and OpenCode
  (`../opencode`). Planned: Codex.

## Non-goals (draft)

- Not removing judgment. Taste and judgment stay in prose.
- Not built for everyone first. It is built for this repository first, and
  usable by anyone with Nix (`claude-kategory`).
- Not a sandbox. Hooks enforce the flow best effort, and `state override`
  is the escape hatch. More enforcement comes later. The flows give the
  agent the flexibility it needs to do its job well, and no more.
