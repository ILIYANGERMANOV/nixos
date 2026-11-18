---
paths:
  - "programs/agents/kernel/**"
---

## The kernel favours the better design

**Backwards compatibility is not important in the kernel: make breaking
changes confidently when they lead to a better long-term design.**

- Old event logs must keep replaying: keep old step decoders, or a legacy
  graph fallback as `State.Flow.Legacy` does, until no old run is live.
- Prefer general, category-theory-aligned designs (sums, cases, Elgot
  iteration and their laws) over special-case building blocks. The model and
  its laws live in `docs/adr/0018-category-model-haskell-state.md`,
  `docs/adr/0019-composable-flows.md` and, for the flow core that replaces
  0019's word table, `docs/adr/0020-flow-core-from-sums-and-elgot.md`; its
  effects, `docs/adr/0021-flow-effects.md`.
- Example: ADR 0019 kept `Choice` and `Route` partly for log and graph
  compatibility. ADR 0020 dropped them for `choice` and `choiceLoop` built
  from `Case`, `Exit` and `Loop`, breaking old logs.
- `state` keeps a **necessary and sufficient** command set: every command
  the chief and the flows need, nothing more. Each command's output carries
  the context to act on it, so an agent drives `state` from its output alone.
- **Vendor-free**: `state` knows nothing of the harness running the agents
  (Claude Code, OpenCode, Codex). It is as helpful as its own data allows:
  run logs, events, timestamps. Harness-specific code lives in a backend.
