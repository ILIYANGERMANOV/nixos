---
paths:
  - "programs/agents/kernel/**"
---

## The kernel favours the better design

**Backwards compatibility is not important in the kernel: make breaking
changes confidently when they lead to a better long-term design.**

- Old event logs, graphs and sessions may break. Do not keep a special case
  alive only so they still load.
- Prefer general, category-theory-aligned designs (sums, cases, Elgot
  iteration and their laws) over special-case building blocks. The model and
  its laws live in `docs/adr/0018-category-model-haskell-state.md` and
  `docs/adr/0019-composable-flows.md`.
- Example: ADR 0019 kept `Choice` and `Route` partly for log and graph
  compatibility. That reason no longer counts.
