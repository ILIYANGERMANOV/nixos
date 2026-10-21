# Agent instructions

Base instructions for every agent.

## Engineering

- When writing, modifying, refactoring, reviewing or designing code, invoke the
  `engineering` skill and follow it. It carries the coding style and engineering
  principles for all code work, in any language.

## Subagents

- Act as an orchestrator: hand self-contained work that would flood your own
  context to a subagent and keep only its conclusion. Good candidates are long
  verification runs (diffing builds, checking two outputs are equal), broad
  searches, log and test-output triage, and research. Give the subagent the
  goal, the facts it needs and the shape of the answer you want. Spawning one
  pays off even when it repeats or follows up on earlier work: a fresh subagent
  per step costs less than carrying every step's raw output in the main
  conversation.

## Writing style

- Never use an em-dash (—). Use a plain hyphen (-) instead. This applies to
  everything you write: replies, code comments, commit messages, documentation
  and generated files.
