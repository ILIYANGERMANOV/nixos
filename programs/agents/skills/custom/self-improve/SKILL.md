---
name: self-improve
description: Finds where past agent sessions on this machine lost tokens and wall time without buying quality - bloated contexts, cache rewrites, redundant or chained checks, sleep loops, failing commands, missing tools, wasteful hand-offs between agents - and what the quality loop bought, never counting time waiting on the user. Measures the transcripts with a deterministic analyzer, then runs the engineer flow primed with that data - research, an interview on the numbers, proposals ranked by net value, the fixes the user picks delivered as one PR. Never trades quality for a saving, and proposes spending more where it buys significant quality. Takes optional suspected bottlenecks to confirm or refute.
disable-model-invocation: true
argument-hint: "[window] [suspected bottlenecks]"
---

# Self-improve

An `engineer` run primed with this machine's own session data. `$ARGUMENTS`
(may be empty): a window in it ("last 7 days") becomes `--since`; the rest are
suspected bottlenecks.

## 1. Measure

```
run=$(mktemp -d /tmp/self-improve.XXXXXX)
python3 -I ${CLAUDE_SKILL_DIR}/scripts/analyze.py [--since ISO] [--project SUBSTR] [--compare ISO] > $run/report.md
```

`$run` below means that directory's path, written out: shell state does not
persist between calls. The default window starts at the previous
`/self-improve` invocation. Read the head with
`sed -n '1,/^## sessions$/p' $run/report.md`, then by their index range the
sections whose headline shows the largest cost (effective tokens or
minutes), about the top 5. `${CLAUDE_SKILL_DIR}/references/metrics.md` says how to
read them.

Its `state-log` section reads the run store's projection tables read-only.
The kernel builds them when it opens the store. If the analyzer says the store
has no current projections, run `state sql 'SELECT 1'` once, then run it again.

Before you brief researchers, read the run store:

- `state report runs|steps|signals|gaps|waits`: one fixed TSV report each.
  Each takes `--since` and `--run <id>`. `--since` takes an RFC 3339
  date-time, such as `2026-11-20T00:00:00Z`: the analyzer's window start.
- `state sql "<select>"` on the views, for what the reports leave open:
  `v_steps` (step visits), `v_signals` (refusals, stops, overrides) and
  `v_sessions` (harness sessions). `state sql "SELECT sql FROM sqlite_schema"`
  prints every table and view with its column comments. The
  [read API](https://github.com/ILIYANGERMANOV/nixos/blob/main/docs/harness/RUN-LOOP.md#the-run-store)
  says more.

Never read a transcript yourself: researchers do.

## 2. Prime the engineer

Write `$run/prompt.md`, the engineer's task:

- **Goal**: cut the tokens and wall time agents spend without buying quality,
  and spend more where it buys significant quality.
- **Facts**: each lead from the report with its numbers (section, row, cost
  in effective tokens or minutes). Each finding from `state report` or
  `state sql` with its run id and numbers. Each suspected bottleneck to
  confirm or refute. The report and `metrics.md` paths, and that `metrics.md`
  holds the transcript layout for researchers.
- **Standards**:
  - Numbers, never guesses: a bottleneck is real once transcripts or
    outcomes show its cost or the quality it lost; a refuted suspicion is
    reported with its numbers.
  - Order by net value: saving weighed against quality impact (none, risk or
    gain, with evidence). A risk, or an unknown impact, ranks below every fix
    without one and is never the recommended option.
  - Waiting on the person is never a bottleneck; never propose fewer
    questions.
  - Quality is the bar: refactor, review, fix, QA, tests and full CI stay.
    Make a step cheaper before rarer; weaken one only when outcomes over a
    large enough sample show it catches nothing a later gate does not. A
    security or data-loss check is insurance, judged by what a miss costs.
- **Known levers**: `${CLAUDE_SKILL_DIR}/references/playbook.md`.
- **Delivery**: one PR in the target repo (default ILIYANGERMANOV/nixos: the
  cwd is its checkout, or the prompt names it) holding the fixes the user
  picks; its body states the before numbers and, where measurable, the after
  numbers. The rest, and fixes in other repos, become follow-up `/engineer`
  runs, named in the delivery.

## 3. Engineer

Invoke the `engineer` skill in this session with `$run/prompt.md` as
its task, and follow it unchanged.
