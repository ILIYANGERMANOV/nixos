# `state` records the engineer flow as events and advises the next arrow

ADR 0012 made `/engineer` a state machine in prose and left one follow-up: a
programmatic state machine. ADR 0014 says how such a program is built. This
ADR decides the first one: `state`, a vendor-free program beside `ctx` that
records every transition of a run as an event, folds the log into the current
state, and advises the next arrow with its mechanical payload. It never
refuses. Design: #329; implementation: #331.

Amended by ADR 0016: advisory hooks now write the events a program can
derive. Superseded by ADR 0018: the Python `state` is deleted, and the Haskell
kernel records, folds and advises, and refuses an arrow its flow lacks. A JSONL
log stays, in a new version that does not read this one's.

## Evidence

Measured on this machine over 53 lead sessions from 2026-10-24, the 4 runs
under the current flow sampled in depth:

- The flow itself holds. The stop rule is in 12 of 12 new worker briefs,
  no review ran without `--requirements`, `--fixes` named the right commit 10
  of 10 times, no worker asked the user, nothing got stuck.
- The record drifts. The progress file was missing in 4 of 8 sampled runs and
  misnamed in 2 of those 4. The notes directory name deviated in 5 of 7.
- The mechanics are retyped. The stop rule appears in 13 of 14 worker briefs
  with wording drift. A refactorer brief is about 100 percent skeleton, a
  review-lead brief about 80, a fixer brief about 56, an implementer brief
  about 41, a researcher brief about 9. Briefs are 10k to 27k characters of a
  lead's 31k to 57k output tokens per run.
- Prose reads are not the cost: 0.7k to 17k tokens per run.

So, by ADR 0013's bar, a program is justified for the record and the
mechanics, and not for enforcement or for token savings on prose.

## Decisions

- **Advisory.** `state next` prints advice, never a refusal: `SPAWN <role>`,
  `ASK <what>`, `WAIT ci`, `RUN <cmd>`, `STUCK <why>` or `DONE` on line 1, then
  facts, in the `ctx` output style. Hooks that deny tool calls are out of
  scope: the violations they would catch measured 0 in the new runs.
- **Event-sourced, JSONL.** The log is `events.jsonl` in the notes directory,
  one object per line, append-only, parsed strictly (ADR 0014). JSONL over
  SQLite: stdlib, readable on a phone, diffs in git, one writer and about 50
  events per run, and the self-improve analyzer already parses JSONL.
- **The program is the source of the table; the prose holds pasted copies a
  test guards.** `state render` prints the skill's `## States` block and the
  engineer's rows of the Quality table; `test_flow.py` fails when a committed
  copy differs and prints the block to paste. Chosen as the simplest, over
  rendering `SKILL.md` at build (the committed file would differ from the
  installed one, and the modes guard scans sources only) and over inline
  shell at skill invocation (not verified for a preloaded skill).
- **All 10 steps; steps 1 to 3 are two states with self-loops.** `Ctx` loops
  on `researched` and `asked` without a cap and leaves on `planned`; `Propose`
  loops on `proposed` and leaves on `confirmed` or `adjusted`. The program
  drives nothing before step 4. Its advice in `Ctx` shows the counts against
  what is typical (at least one researcher and one question; usually 2 to 3
  researchers and 4 to 12 questions), as information.
- **A refused record is stored as a `refused` event.** Agents chain
  `state record ...; state next` or pipe it through `tail`, so a refusal on
  stderr was lost. The pure `decide(state, parsed) -> Decision(append,
  reached, reply)` takes the parse result of a `record` or `handback`: a
  parse or flow refusal decides `append = (Refused(message, fix),)` and
  `reply` the refusal, success the events `record` folds and no reply. The
  shell writes `append` and prints `reply`: exit 2, the stderr unchanged.
  `refused` is taken in every state and never moves the step; the next
  accepted event or override clears it, a later refusal replaces it. While
  one is pending, `warning(state)` puts `WARN refused, not recorded:
  <message>` and its `fix:` line first in `state next`, `state show` and
  every hook's context. A PR sync the flow refuses is told, never stored.
  An older `state` cannot read a log holding one.
- **`state override <state> <why>` is the escape.** The target is explicit so
  the fold stays in sync and `next` stays correct. It is the one event whose
  target is not a function of the table.
- **Quality and Size are events; the engineer's guards are code.**
  `quality(mode)` once, `size(Trivial|Normal)` once, `grew(why)` from Trivial
  to Normal and never back, a missing knob recorded as `defaulted`. The
  engineer's columns of the Quality table (Researchers, Proposals, Implement,
  Refactor, Skill dry run, Re-reviews, Full review of a fix to) and the
  Trivial skip table become pure guards of (quality, size, state) plus a git
  fact. The one judgment the lead supplies is `--touches` on a fix. Rows other
  roles read stay in `quality.md`, which remains the one human-readable
  definition.
- **`state brief <role>` prints the brief skeleton**; `next` stays short. The
  skeleton holds the worktree, base, plan path, `Quality:` and `Size:` lines,
  the stop rule or the plan-wrong line, the checks and the hand-back rule.
- **`state handback <role>` parses a worker's hand-back** from stdin: the
  first token `READY | NEEDS_DECISION | GREW | BLOCKED | FAILED` and a
  review-lead's `Reviewed head: <sha>`, and records the event.
- **`state show` is the progress view.** It replaces the hand-written
  `report.md`; the PR body updates are written from it.
- **Packaged beside `ctx`.** `programs/agents/state/`: the stdlib Python package
  `state`, pure modules (`model`, `flow`, `core`, `codec`, `cli`) and the effects
  in `effects`, entered through `main.py`. Imported as `state.core`, so its
  module names never clash on the shared pytest path. `default.nix` copies them
  to the store and wraps `python -P -m state.main` as the `state` binary. It is exported from
  `programs/agents/default.nix`, on PATH through the base profile. It names no vendor path. A delegated engineer
  passes its brief's report path, so a run in another worktree keeps its own
  log.

## Shape

```text
Event =
  | Started(notes, session, delegated)
  | Quality(mode) | Size(size) | Grew(why)
  | Defaulted(knob, value)
  | Researched(n) | Asked(n)
  | Planned(path) | Proposed(mode)
  | Confirmed | Adjusted
  | Drafted(url, base)
  | Implemented(head) | Refactored(head)
  | Reviewed(head, rows, verdicts)
  | Fixed(head, touches?)
  | Ci(head, failing?)
  | Blocked(q, kind) | Resolved(q, answer)
  | Overridden(to, why)
  | Ready(url)
  | Refused(message, fix)

Advice = Spawn(role, args) | Ask(what)
       | Wait(ci) | Run(cmd)
       | Stuck(why) | Done
```

The states are ADR 0012's, with the blocker and stuck arrows from any state.
The transition inventory counts 12 states and 32 rows, 18 of them with a fully
mechanical payload.

```text
state init --notes <dir> [--delegated]
state record <event> [args]
state handback <role> < text
state next
state brief <role>
state show
state override <state> <why>
state render
state help
```

## Considered options

- **Prose only.** Rejected: it works today, but there is no replayable record,
  and drift returns with a model change.
- **Hooks that enforce** (deny a spawn out of order, a Stop hook that refuses
  "done"). Rejected for now: the violations measured 0, and ADR 0013's read
  guard example shows how a guard blocks legitimate paths. A Stop hook that
  reads the log may come later.
- **Claude Code dynamic workflows.** Rejected: a research preview, no user
  input mid-run, no shell in the script, stripped from subagents so it cannot
  nest under `/10x-engineer`, and vendor-specific.
- **An Agent SDK outer loop.** Rejected: full determinism, but it loses the
  phone, Remote Control and `AskUserQuestion`.
- **Steps 4 to 10 only.** Rejected: the record would start late and the notes
  directory drift would continue.
- **`flow` as the name.** Rejected by the user: `state`.

## Consequences

- The engineer skill keeps its rules, map and judgment; its mechanics become
  one line each naming `state next`, `state brief`, `state handback` and
  `state record`.
  `blockers.md` loses the progress file format, `trivial.md` the skip table,
  `review.md` all but the judgment of picking rows.
- `test_<module>.py` beside each module prove ADR 0014's laws (`test_core.py`),
  the table row by row, and the prose guard (`test_flow.py`); `python-tests`
  runs them.
- The self-improve analyzer can replay `events.jsonl` for the per-PR metrics
  in #312.
- After a few runs, self-improve measures the before and after: record
  completeness, brief characters written by the lead, and the adherence
  counts above.
