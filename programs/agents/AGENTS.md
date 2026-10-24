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

## Reading files

- Read one file per command, or `grep -n` first and then read just that range
  with `sed -n`. Do not `cat` several large files in one command: output over
  the inline limit is spilled to a file, and reading that back pays for it
  twice.

## Writing style

- Never use an em-dash (—). Use a plain hyphen (-) instead. This applies to
  everything you write: replies, code comments, commit messages, documentation
  and generated files.
