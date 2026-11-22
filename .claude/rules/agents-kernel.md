---
paths:
  - "programs/agents/kernel/**"
---

## The kernel favours the better design

**Backwards compatibility of the kernel's code, graphs and interfaces is not
important: make breaking changes confidently when they lead to a better
long-term design.**

- Old event logs need not replay: a log the current graph refuses is an
  error, and `state init --notes <a new dir>` starts afresh. No legacy graph
  fallback and no log migration.
- Prefer general, category-theory-aligned designs (sums, cases, Elgot
  iteration and their laws) over special-case building blocks. The model and
  its laws live in `docs/adr/0018-category-model-haskell-state.md`,
  `docs/adr/0019-composable-flows.md` and, for the flow core that replaces
  0019's word table, `docs/adr/0020-flow-core-from-sums-and-elgot.md`; its
  effects, `docs/adr/0021-flow-effects.md`.
- Example: ADR 0019 kept `Choice` and `Route` partly for log and graph
  compatibility. ADR 0020 dropped them for `choice` and `choiceLoop` built
  from `Case`, `Exit` and `Loop`.
- `state` keeps a **necessary and sufficient** command set: every command
  the chief and the flows need, nothing more. Each command's output carries
  the context to act on it, so an agent drives `state` from its output alone.
- **Vendor-free**: `state` knows nothing of the harness running the agents
  (Claude Code, OpenCode, Codex). It is as helpful as its own data allows:
  run logs, events, timestamps. Harness-specific code lives in a backend.
- **The Haskell `state` code is the source of truth for the flow.** Nix
  holds only data that Haskell lacks: `flows/steps.nix` names no step's
  types or outcomes, which the kernel's layers already state.
