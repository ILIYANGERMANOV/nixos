---
paths:
  - "programs/agents/skills/**"
  - "programs/agents/kernel/**"
---

## Agent gaps

A **gap** is friction an agent actually hit with a flow, a skill or
`state`, not tech debt. A bug that makes agent runs harder counts;
refactors, DRY and large files do not.

- Record only a gap you are certain of. Record it with
  `state record gap --kind <k> --severity <s> "<text>"`, never in a loose
  file; `state show` lists them.
- Other facts take their typed row first: `user_needed` the moment the
  user must do something by hand, `instructed` for the user's words
  verbatim. `stopgap` comes last, only when no typed command fits.
- A worker writes a hand-back line per gap instead, on its own line after
  line 1: `Gap: <kind> <severity> <text>`.
- Severity: `blocker` you cannot go on, `slowdown` it cost time,
  `papercut` minor friction.
- `state resume` lists the open gaps by `<run:seq>`. Run
  `state gap proposed <run:seq> --pr <url>` when the fix PR opens and
  `state gap fixed <run:seq> --pr <url>` when it merges, or
  `state gap wontfix <run:seq> "<reason>"`.
- A fix is a **clear win** only if: the gap is proven on current
  `origin/main`; the fix is deterministic and low risk; it adds no new
  special state, flag, rule or judgment call; `state` keeps a necessary and
  sufficient command set whose output carries the context to act; it saves
  tokens or round trips or adds reliability; it uses the strongest rung of
  the logic ladder (`agents-logic-ladder.md`); the kernel stays vendor-free.
