# Agent instructions

Base instructions for every agent.

## Engineering

- When writing, modifying, refactoring, reviewing or designing code, invoke the
  `engineering` skill and follow it. It carries the coding style and engineering
  principles for all code work, in any language.
- Before opening a pull request, or when writing or updating a PR description,
  invoke the `pr-description` skill and follow it.

## Subagents

- Act as an orchestrator: hand self-contained work that would flood your own
  context to a subagent and keep only its conclusion. Good candidates are long
  verification runs (diffing builds, checking two outputs are equal), broad
  searches, log and test-output triage, and research. Give the subagent the
  goal, the facts it needs and the shape of the answer you want. Spawning one
  pays off even when it repeats or follows up on earlier work: a fresh subagent
  per step costs less than carrying every step's raw output in the main
  conversation.
- The exception: when exploring feeds directly into a change, one subagent both
  explores and implements. Splitting them makes the implementer re-read
  everything the explorer already read.
- Run subagents in the background by default. Use the foreground only when your
  very next step needs the result and nothing else can usefully happen
  meanwhile, so you stay free to do other work and the person can steer.
- Trust a subagent's verified report and the CI results. After a follow-up
  edit, re-run only the checks that edit affects, and never re-fetch package
  indexes.
- Hand back in 300 words or fewer, unless the invoked skill sets its own
  return format. Detail goes in commits, the PR or a file.
  Relay a hand-back to the user only when it changes what they need to know.

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
- Subagents never wait on CI or long builds: they hand back, and the parent
  waits.
- Wait on a pull request's CI without blocking: after your final push, call
  `subscribe_pr_activity` and end your turn, so CI results wake you. An event
  for a commit that is not the branch head, or for your own action (your
  push, `ready_for_review`), needs nothing: end the turn without a tool call.
  Where subscribing is unavailable or refused, run `gh pr checks <n> --watch`
  as a background Bash command (`run_in_background`) instead; it exits 8 while
  checks are pending, which is not a failure.
- Fanning out in parallel, launch one agent first and the rest after it, so
  they share its cached prefix.

## Writing style

- Never use an em-dash (—). Use a plain hyphen (-) instead. This applies to
  everything you write: replies, code comments, commit messages, documentation
  and generated files.
