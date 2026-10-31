# Agent instructions

Base instructions for every agent.

## Engineering

- When writing, modifying, refactoring, reviewing or designing code, invoke the
  `engineering` skill and follow it. It carries the coding style and engineering
  principles for all code work, in any language. A `pragmatic-review` agent
  loads it only when its brief says so.
- Before opening a pull request, or when writing or updating a PR description,
  invoke the `pr-description` skill and follow it. A draft PR whose body is
  the plan may skip it until hand-over.
- Start every task with `git fetch origin main`. Branch from `origin/main` and
  diff against it, so you never build on or compare with a stale checkout.

## Asking

Asking is cheap; the user's understanding is the bottleneck. A wrong guess
costs rework, tech debt and bugs.

- These rules bind the agent talking to the user. Before building a
  non-trivial change, propose a plan and ask whether it matches the user's
  understanding. A one-line, unambiguous edit needs no plan round-trip.
- Ask about every technical, architecture, design, production and approach
  decision until nothing is unclear, and always when something is ambiguous.
- Research before you ask. Never ask what the code, the docs or a tool can
  answer, and never re-ask what the user decided. When a prompt only names
  what to research, plan the research topics yourself, group the questions,
  and launch one research agent per group before your first question.
- Ask with `AskUserQuestion`, one question per call: 2-4 concrete options,
  your recommendation first with `(Recommended)` in its label, context in the
  option descriptions. Never ask permission to run builds, tests, installs or
  git operations.
- A subagent cannot ask the user. It builds what it was briefed and hands
  any open decision back to its caller in its report, finishing the work the
  decision does not block rather than stopping or guessing.

## Quality

Every brief carries `Quality: <mode>`; a brief with no mode means Balanced. An
agent may lower or raise it for a subtask. A skill's text is Max: it names only
what Balanced and POC change, and no branch means as written.

- **POC**: prove the idea cheaply. One quick refactor and one quick review with
  no DEEP security pass, then a PR labelled `POC`, not merge-ready and never
  auto-merged.
- **Balanced** (default): fewer review agents, a fix pass, one `--fixes`
  re-review and one final small fix. Security depth stays.
- **Max**: every step.

## Subagents

- Act as an orchestrator: hand self-contained work that would flood your own
  context to a subagent and keep only its conclusion. Good candidates are long
  verification runs (diffing builds, checking two outputs are equal), broad
  searches, log and test-output triage, and research. Give the subagent the
  goal, the facts it needs and the shape of the answer you want. A fresh
  subagent per step costs less than carrying every step's raw output.
- The exception: when exploring feeds directly into a change, one subagent both
  explores and implements. Splitting them makes the implementer re-read
  everything the explorer already read.
- Run subagents in the background by default. Use the foreground only when your
  very next step needs the result and nothing else can usefully happen
  meanwhile, so you stay free to do other work and the person can steer.
  A subagent waits for the agents it spawned: ending its turn is its
  hand-back.
- Trust a subagent's verified report and the CI results, and never re-fetch
  package indexes.
- A subagent works with `git -C <path>` or on its own branch. It never checks
  out the branch the orchestrator's worktree holds: git refuses a branch
  another worktree has checked out.
- Hand back in about 250 words, never over 300, unless the invoked skill
  sets its own return format. Detail goes in commits, the PR or a file.
  Relay a hand-back to the user only when it changes what they need to know.

## Checks

A full check (`just check`, the whole test suite) takes minutes. Spend it once.

- While iterating, run the narrowest check that covers the edit: one test, a
  typecheck, a single `nix build .#checks.<system>.<name>`.
- Implementers, fixers and refactor passes run targeted checks only: the
  lint, format and tests that cover their diff.
- A large change gets one full check on its final state: one that touches
  build or evaluation logic, many modules, or code with tests beyond the
  targeted ones. The orchestrator owns that: it hands the duty to the last
  agent to push, or runs it in a fresh agent when the last pass changed
  nothing or that agent hands it back. Rerun it only after a code edit, never after a docs-only edit.
  CI has the final say.
- A project's own instructions win where they are stricter, such as one
  that runs its full check on the final state of every change.
- Never chain steps the full check already runs: no build, test or lint in
  front of a `just check` that runs them.
- Run anything expected to take over a minute with `run_in_background`. It
  wakes you when it exits: never `sleep`, loop on `until`, or poll its output.
  A subagent's background task dies at its hand-back and nothing wakes it, so a
  subagent runs it in the foreground with `timeout: 600000` instead.
- A subagent's cache lasts 5 minutes, and rewriting a large context costs far
  more than a small one. So an agent past about 150k tokens never waits on a
  check expected over about 4 minutes: it commits, pushes if the branch is
  pushed, and hands back naming the check. Its caller spawns a fresh small agent
  to run it, and a failure goes to a fresh fixer.
- Foreground Bash caps at 10 minutes. If a check may pass that and a rerun
  resumes it, the subagent runs it under `timeout 590` and reruns it on exit
  124, since the wait guard blocks waiting on a log. If no rerun resumes it, it
  hands back and the top-level agent runs it with `run_in_background`.
- Search with `rg`. `grep` may be ugrep, which rejects bounded repeats such
  as `.{0,250}` as too complex.

## Context budget

Every call re-sends the whole context, so a large agent pays for it on every
step.

- Stay under about 220k tokens of context. Past it, commit, push if the branch
  is pushed, hand back a short note - files touched, decisions, what remains,
  how to verify - and stop. The orchestrator continues with a fresh agent
  briefed from that note.
- Never send new scope to a large agent: start a fresh one.
- The prompt cache expires after about 5 minutes idle. Never resume a large
  agent after a gap; spawn a fresh one from a summary.
- Subagents never wait on or poll CI or deploys: they hand back, the parent
  waits, and a guard enforces it. A check they run is still theirs to wait for.
- Wait on a pull request's CI without blocking: after your final push, call
  `subscribe_pr_activity` and end your turn, so CI results wake you. An event
  for a commit that is not the branch head, or for your own action (your
  push, `ready_for_review`), needs nothing: end the turn without a tool call.
  Where subscribing is unavailable or refused, run `gh pr checks <n> --watch`
  as a background Bash command (`run_in_background`) instead, with no `sleep`
  in front, even right after a push; it exits 8 while checks are pending,
  which is not a failure.
- Fanning out in parallel, launch one agent first and the rest after it, so
  they share its cached prefix.

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
