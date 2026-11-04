# Agent instructions

Base instructions for every agent.

## Engineering

- When writing, modifying, refactoring, reviewing or designing code, invoke the
  `engineering` skill and follow it. It carries the coding style and engineering
  principles for all code work, in any language. A review agent loads it only
  when its brief says so.
- Without a Skill tool, invoking a skill means reading
  `~/.claude/skills/<name>/SKILL.md` and following it, with your prompt as its
  input. A skill already in your context is loaded: never read it again.
- Start every task with `git fetch origin main`. Branch from `origin/main` and
  diff against it, so you never build on or compare with a stale checkout.

## Quality

Every brief carries two knobs, and a brief you write passes both on.
`Quality: <mode>` is the user's: POC, Balanced (the default) or Max. A role
that varies by mode gets the Quality table.

`Size: Trivial|Normal` is the second knob, Normal when absent. Only the
engineer leading the task sets it, once. Trivial only skips steps. A worker
that finds a Trivial task bigger than briefed starts its hand-back with
`GREW <why>`, and the engineer sets Normal for good.

## Subagents

- A subagent cannot ask the user. It builds what it was briefed and hands
  any open decision back to its caller in its report, finishing the work the
  decision does not block rather than guessing, unless its brief says to stop.
- A subagent waits for the agents it spawned: ending its turn is its
  hand-back.
- A subagent works with `git -C <path>` or on its own branch. It never checks
  out the branch the orchestrator's worktree holds: git refuses a branch
  another worktree has checked out.
- Hand back in about 250 words, never over 300, unless the invoked skill
  sets its own return format. Detail goes in commits, the PR or a file.

## Checks

A full check (`just check`, the whole test suite) takes minutes. Spend it once.

- While iterating, run the narrowest check that covers the edit: one test, a
  typecheck, a single `nix build .#checks.<system>.<name>`.
- Implementers, fixers and refactor passes run targeted checks only: the
  lint, format and tests that cover their diff.
- A project's own instructions win where they are stricter, such as one
  that runs its full check on the final state of every change.
- Never chain steps the full check already runs: no build, test or lint in
  front of a `just check` that runs them.
- A subagent's background task dies at its hand-back and nothing wakes it, so a
  subagent runs anything long in the foreground with `timeout: 600000`.
- Foreground Bash caps at 10 minutes. A check that may pass that runs under
  `timeout 590` and reruns on exit 124 if a rerun resumes it, since the wait
  guard blocks waiting on a log. If no rerun resumes it, a subagent hands back.
- A subagent's cache lasts 5 minutes, and rewriting a large context costs far
  more than a small one. So an agent past about 60k tokens never runs a check
  expected over about 4 minutes itself: it commits, pushes if the branch is
  pushed, and hands back naming the check. Its caller spawns a fresh `checker` agent
  to run it, and a failure goes to a fresh fixer.
- Search with `rg`. `grep` may be ugrep, which rejects bounded repeats such
  as `.{0,250}` as too complex.

## Context budget

Every call re-sends the whole context, so a large agent pays for it on every
step.

- Stay under about 220k tokens of context. Past it, commit, push if the branch
  is pushed, hand back a short note - files touched, decisions, what remains,
  how to verify - and stop. The orchestrator continues with a fresh agent
  briefed from that note.
- Subagents never wait on or poll CI or deploys: they hand back, the parent
  waits, and a guard enforces it. A check they run is still theirs to wait for.

## Writing for people

PR bodies, explanations, replies and reports a person reads:

- Simple words, short sentences. No walls of text: little prose, bullets
  over paragraphs.
- One or more visuals where they help: a diagram, a table, pseudo-code.
- Text you post (PR comments, reviews, replies) without the user approving
  it opens with `🤖 Posted by an AI agent. No human has read it yet.` Text
  the user approved carries no disclosure.

## Writing style

- Never use an em-dash (—). Use a plain hyphen (-) instead. This applies to
  everything you write: replies, code comments, commit messages, documentation
  and generated files.
