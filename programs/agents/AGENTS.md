
# Leading a task

What the agent running a session needs on top of the instructions above.
Trimmed subagent roles do not get this part.

## Pull requests

- Before opening a pull request, or when writing or updating a PR description,
  invoke the `pr-description` skill and follow it. A draft PR whose body is
  the plan may skip it until hand-over.

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
  and launch one `researcher` agent per group before your first question.
- Ask with `AskUserQuestion`, one question per call: 2-4 concrete options,
  your recommendation first with `(Recommended)` in its label, context in the
  option descriptions. Never ask permission to run builds, tests, installs or
  git operations.

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
- Trust a subagent's verified report and the CI results, and never re-fetch
  package indexes.
- Relay a hand-back to the user only when it changes what they need to know.

## Checks

- A large change gets one full check on its final state: one that touches
  build or evaluation logic, many modules, or code with tests beyond the
  targeted ones. The orchestrator owns that: it hands the duty to the last
  agent to push, or runs it in a fresh agent when the last pass changed
  nothing or that agent hands it back. Rerun it only after a code edit, never after a docs-only edit.
  CI has the final say.
- Run anything expected to take over a minute with `run_in_background`. It
  wakes you when it exits: never `sleep`, loop on `until`, or poll its output.
- Foreground Bash caps at 10 minutes. If a check may pass that and a rerun
  resumes it, the fresh small check agent runs it under `timeout 590` and
  reruns it on exit 124, since the wait guard blocks waiting on a log. If no
  rerun resumes it, it hands back and the top-level agent runs it with
  `run_in_background`.

## Context budget

- Never send new scope to a large agent: start a fresh one.
- The prompt cache expires after about 5 minutes idle. Never resume a large
  agent after a gap; spawn a fresh one from a summary.
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
