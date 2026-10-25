---
name: self-improve
description: Finds where past agent sessions on this machine lost tokens and wall time - bloated contexts, redundant or chained checks, slow builds, sleep loops, failing commands and missing tools - confirms each bottleneck with numbers from the transcripts, asks the user which fixes to make, and delivers each approved fix as a PR through /engineer. Takes optional suspected bottlenecks to confirm or refute.
disable-model-invocation: true
argument-hint: "[suspected bottlenecks]"
---

# Self-improve

Measure how agent sessions on this machine spent tokens and wall time since the
last run, find the bottlenecks, and fix the ones the user approves. Suspected
bottlenecks from the user: `$ARGUMENTS` (may be empty).

## Rules

- **Numbers, never guesses.** A bottleneck is real only once the transcripts
  show its cost in tokens or minutes. A suspicion the data refutes is reported
  as refuted, with the numbers.
- **Rank by measured cost**, tokens and wall time. Time spent waiting on the
  person is not work time: report it apart and never count it as a saving.
- **Keep coverage.** CI keeps its full checks. Gains come from faster local
  check ladders, warm daemons, parallel builds, missing tools and leaner agent
  instructions. A stronger machine is out of scope.
- **Protect your context.** Subagents read the raw transcripts; you keep their
  conclusions. Never read a transcript file yourself.

## 1. Measure

Run the analyzer and read its report (a few KB):

```
python3 -I ${CLAUDE_SKILL_DIR}/scripts/analyze.py [--since ISO] [--project SUBSTR]
```

By default it covers every session started since the previous `/self-improve`
invocation, or everything when there was none. This session counts only up to
the current invocation.
Read `${CLAUDE_SKILL_DIR}/references/metrics.md` for what each section measures
and where it is blind.

## 2. Dig deeper

Spawn background subagents, launching one first and the rest after it. Give
each the transcript layout and measurement rules from `metrics.md`, its
question, and that it answers with numbers and session ids in under 300 words.
They may write their own `jq` or Python over `~/.claude/projects`.

- **One per suspected bottleneck** from the arguments: confirm or refute it.
- **One per lead** the report points at that is worth more than a few minutes
  or a few million tokens: what the agents were doing, and why.
- **One tooling hunt**: failing and `command not found` calls, workarounds,
  tools installed ad hoc (`nix shell`, `pip install`, `npx`), slow cold builds,
  and the commands each repository's agents run most.

## 3. Report and ask

Present the confirmed bottlenecks ranked by cost, each with its numbers and
the sessions they came from, grouped as:

1. **nixos skills** - `programs/agents/skills`, `AGENTS.md`.
2. **software-factory config** - `programs/software-factory`, `modules/nixos/server`.
3. **A repository's own flake and tooling** - its dev shell, `Justfile`,
   `CLAUDE.md`, test commands.
4. **Other ideas.**

Then ask one `AskUserQuestion` per bottleneck, with suggested fixes as options,
recommended first. `${CLAUDE_SKILL_DIR}/references/playbook.md` holds the fixes
that worked before.

## 4. Fix

Bundle all approved fixes for one repository into a single `/engineer` run,
which opens one PR for that repository; a fix spanning repositories gets one
run per repository. Repositories live under `~/repos/<name>`; follow the
global worktree and branch rules. Each PR body states the before numbers from
this analysis and, where the fix is measurable locally, the after numbers.

Done when every approved fix has a PR with green CI, and the user has a short
summary: each bottleneck, its cost, its PR or why it was left.
