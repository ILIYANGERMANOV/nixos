---
name: self-improve
description: Finds where past agent sessions on this machine lost tokens and wall time without buying quality - bloated contexts, redundant or chained checks, slow builds, sleep loops, failing commands, missing tools and wasteful communication between subagents, never time waiting on the user. Measures what the quality loop bought (review yield, regressions, CI failures, user corrections), audits the skills, shared instructions and past /qa runs, and hunts tooling that sets agents up for success. Confirms each bottleneck with numbers, weighs each saving against its quality impact, asks the user which fixes to make, and delivers each approved fix as a PR through /engineer. Never recommends a fix that puts quality at risk, and proposes spending more where it buys significant quality. Takes optional suspected bottlenecks to confirm or refute.
disable-model-invocation: true
argument-hint: "[suspected bottlenecks]"
---

# Self-improve

Measure what agent sessions on this machine spent since the last run and what
quality it bought, find the bottlenecks, and fix the ones the user approves.
Suspected bottlenecks from the user: `$ARGUMENTS` (may be empty).

## Rules

- **Numbers, never guesses.** A bottleneck is real only once the transcripts or
  the outcomes show it: its cost in tokens or minutes, or the quality it lost.
  A suspicion the data refutes is reported as refuted, with the numbers.
- **Order by net value**: measured tokens and wall time saved, weighed against
  the quality impact (none, risk or gain, with its evidence). A fix with a risk
  ranks below every fix without one, whatever its saving. An unknown quality
  impact counts as a risk.
- **Waiting on the person is never a bottleneck.** Time waiting on a prompt or
  an `AskUserQuestion` is not work time and never a saving
  target: it can be a second or a day. Asking is cheap and important; never
  propose fewer questions.
- **Quality is the bar, and resources the variable.** The goal is working,
  verified software, made efficiently. Refactor, review, fix, QA, tests and
  CI stay. Make a step cheaper before making it rarer: same coverage, fewer
  tokens. Propose removing or weakening a step only when the quality review
  shows from outcomes that it catches nothing a later gate does not, and the
  sample is large enough to say so. Low yield alone proves nothing for a
  security or data-loss check: it is insurance, judged by what a miss costs.
  A shortcut with a net negative on quality is rejected, however large the
  saving. CI keeps its full checks. Gains come from true waste, process
  fixes, better tooling and leaner instructions, and spending more is a valid
  proposal when it buys significant quality. A stronger machine is out of
  scope.
- **Protect your context.** Subagents read the raw transcripts; you keep their
  conclusions. Never read a transcript file yourself.

## 1. Measure

Run the analyzer and read its report (about 15 KB):

```
python3 -I ${CLAUDE_SKILL_DIR}/scripts/analyze.py [--since ISO] [--project SUBSTR]
```

By default it covers every session started since the previous `/self-improve`
invocation, or everything when there was none. This session counts only up to
the current invocation.
Read `${CLAUDE_SKILL_DIR}/references/metrics.md` for what each section measures
and where it is blind.

## 2. Dig deeper

Spawn background `subagent_type: researcher` agents at `Quality: Max`, with
`/tmp/self-improve/` as the notes directory, launching one first and the rest
after it. Give each the transcript layout and measurement rules from
`metrics.md`, its question, and that it answers with numbers and session ids.
They may write their own `jq` or Python over `~/.claude/projects`.

- **One last-PR check**: find the last self-improve PR
  (`gh pr list --state all --search "self-improve in:title"`), read its body and
  list what was an issue and what was fixed. For each fix, check in this window
  whether it held or the issue came back. An issue it left open is a lead.
- **One per suspected bottleneck** from the arguments: confirm or refute it.
- **One per lead** the report points at that is worth more than a few minutes
  or a few million tokens: what the agents were doing, and why. A quality
  step's cost alone is no lead: it goes to the quality review with its yield.
- **One quality review**: what the loop bought. From the report's Loop steps,
  Review yield and After hand-back sections, `gh` on the PRs these sessions
  opened and the recipes in `metrics.md`: findings per step that were real
  bugs and what each cost, regressions a fix or refactor introduced, CI
  failures after hand-back and whether a local check would have caught them,
  /final-review and /qa Fails, what the user had to correct, follow-up fixes
  and reverts. It returns three lists: work that adds no quality, gates worth
  their cost that must stay (with numbers), and where spending more would buy
  significant quality. It looks back past the window for outcomes of recent
  PRs, states its sample sizes, and says "not enough data" when that is the
  answer.
- **One communication review**: how agents talk to each other. From the
  report's Agent communication section and the raw briefs and hand-backs:
  brief and hand-back size per agent type, what orchestrators re-read or
  re-verified after a hand-back, duplicated work across agents, follow-up
  messages that fixed a thin brief, explorer-then-implementer splits, large
  results carried in the parent's context that a notes file would have kept
  out, and hand-backs missing what the parent needed, so it spawned again. It
  separates re-verifying that protects quality from re-reading that repeats
  work, and proposes a solution for each inefficiency it confirms.
- **One tooling hunt**: what would set agents up for success. Failing and
  `command not found` calls, workarounds, tools fetched ad hoc (`nix shell`,
  `pip install`, `npx`) by package, slow cold builds, the commands each
  repository's agents run most, and failures recurring across sessions. Also
  what agents wished for: `Unverified` review verdicts and hand-backs saying
  what could not be checked, with their reasons. Tools available but unused
  (an LSP, say), and why. Each active repository's readiness: dev shell,
  `Justfile`, check ladder, `CLAUDE.md`, `QA.md`. Recurring review findings
  of one class that a lint or hook could catch, which saves review tokens
  and raises quality.
- **One `/qa` review** of the sessions that ran `/qa`: failed and retried
  steps, the slowest steps, and what the repository's `QA.md` notes were
  missing. It proposes edits to the `qa` skill or a `QA.md`.
- **One skill audit** of the installed skills and shared instructions
  (`programs/agents/AGENTS.md`, `programs/claude-code/factory-instructions.md`,
  `programs/agents/skills/custom/*`): unclear or ambiguous wording, token cost
  (lines, description length, text repeated across files) and rules that
  contradict each other. Each finding quotes the lines and, where it can,
  points at a session the wording misled. A finding that shortens a rule says
  what the rule protects and keeps it.

## 3. Report and ask

Present the confirmed bottlenecks ranked by net value, each with its numbers,
its quality impact and the sessions they came from, grouped as:

1. **nixos skills** - `programs/agents/skills`, `AGENTS.md`.
2. **software-factory config** - `programs/software-factory`, `modules/nixos/server`.
3. **A repository's own flake and tooling** - its dev shell, `Justfile`,
   `CLAUDE.md`, test commands.
4. **Worth spending more** - where more tokens or time buy significant quality,
   with the evidence.
5. **Other ideas.**

Then ask one `AskUserQuestion` per bottleneck, and per audit finding whose fix
is a real choice, with suggested fixes as options, recommended first. Each
option states its quality impact. A fix with quality risk is never the
recommended option: when every option carries one, mark none recommended. Base
each fix on the data or the quoted text, never a guess. Fix only what the user
approves.
`${CLAUDE_SKILL_DIR}/references/playbook.md` holds the fixes that worked
before.

## 4. Fix

Bundle all approved fixes for one repository into a single `/engineer` run,
which opens one PR for that repository; a fix spanning repositories gets one
run per repository. Repositories live under `~/repos/<name>`; follow the
global worktree and branch rules. Each PR body states the before numbers from
this analysis and, where the fix is measurable locally, the after numbers.

Done when every approved fix has a PR with green CI, and the user has a short
summary: each bottleneck, its cost, its PR or why it was left.
