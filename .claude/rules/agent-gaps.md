---
paths:
  - "programs/agents/skills/**"
  - "programs/agents/kernel/**"
---

## Agent gaps

A **gap** is friction an agent actually hit with a flow, a skill or `state`
(a bug that makes agent runs harder counts). Code tech debt (refactors,
DRY, large files) is not a gap.

- Record only a gap you are certain of, never in a loose file, with
  `state record gap --kind <k> --severity <s> "<text>"`; `state show`
  lists them. A worker writes one hand-back line per gap instead:
  `Gap: <kind> <severity> <text>`.
- Move a gap on with `state gap proposed|fixed <run:seq> --pr <url>`, or
  `state gap wontfix <run:seq> "<reason>"`.
- A fix is a **clear win** only if: the gap is proven on current
  `origin/main`; the fix is deterministic and low risk; it adds no new
  special state, flag, rule or judgment call; `state` keeps a necessary and
  sufficient command set whose output carries the context to act; it saves
  tokens or round trips or adds reliability; it uses the strongest rung of
  the logic ladder (`agents-logic-ladder.md`); the kernel stays vendor-free.
