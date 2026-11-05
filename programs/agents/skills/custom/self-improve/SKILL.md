---
name: self-improve
description: Finds where past agent sessions on this machine lost tokens and wall time without buying quality - bloated contexts, cache rewrites, redundant or chained checks, sleep loops, failing commands, missing tools, wasteful hand-offs between agents - and what the quality loop bought, never counting time waiting on the user. Measures the transcripts with a deterministic analyzer, then runs the engineer flow primed with that data - research, an interview on the numbers, proposals ranked by net value, approved fixes delivered as PRs. Never trades quality for a saving, and proposes spending more where it buys significant quality. Takes optional suspected bottlenecks to confirm or refute.
disable-model-invocation: true
argument-hint: "[suspected bottlenecks]"
---

# Self-improve

An `engineer` run primed with this machine's own session data. Suspected
bottlenecks from the user: `$ARGUMENTS` (may be empty).

## 1. Measure

```
mkdir -p /tmp/self-improve
python3 -I ${CLAUDE_SKILL_DIR}/scripts/analyze.py [--since ISO] [--project SUBSTR] [--compare ISO] > /tmp/self-improve/report.md
```

The default window starts at the previous `/self-improve` invocation. Read the
head with `sed -n '1,/^## sessions$/p' /tmp/self-improve/report.md`, then the sections a lead needs by
their index range. `${CLAUDE_SKILL_DIR}/references/metrics.md` says how to
read them. Never read a transcript yourself: researchers do.

## 2. Prime the engineer

Write `/tmp/self-improve/prompt.md`, the engineer's task:

- **Goal**: cut the tokens and wall time agents spend without buying quality,
  and spend more where it buys significant quality.
- **Facts**: each lead from the report with its numbers (section, row, cost
  in effective tokens or minutes), and each suspected bottleneck to confirm or
  refute. The report and `metrics.md` paths, and that `metrics.md` holds the
  transcript layout for researchers.
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
- **Delivery**: each PR body states the before numbers and, where measurable,
  the after numbers. A fix in another repository is a follow-up `/engineer`
  run, named in the hand-over.

## 3. Engineer

Invoke the `engineer` skill in this session with `/tmp/self-improve/prompt.md`
as its task, and follow it unchanged.
