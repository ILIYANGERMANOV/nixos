# The engineer flow is a state machine where agents research and ask on demand

`/engineer` ran a fixed lifecycle: research and ask up front, then build,
review once, fix once, and hand over. A question a worker hit mid-build had no
path back to the user, and the review loop stopped after one re-review in
every mode. Now each step is a state with named arrows, a Quality mode only
skips arrows, and any worker can hand a blocking question back to the
engineer, who sorts it.

```
Ctx --ask/research--> Ctx --plan--> Prop --simplify--> Prop' --alternative--> Prop'
Prop' x Prop' --ask(first|second|adjust)--> Plan | Ctx
Plan --> draft PR --> Impl --refactor--> Impl' --review--> ImplR <--fix/--fixes (<=N)--> Impl''
any worker/review blocker --> Ctx (engineer triages)
last re-review --> final small fix --> pr-description + notify --> CI --> green: ready + notify | issues: fix
```

The steps keep their numbers 1 to 10, so `/10x-engineer`, `trivial.md` and
resume read the same. The spec is the `## States` table in
`programs/agents/skills/custom/engineer/SKILL.md`, with detail in its
`references/blockers.md` and `references/review.md`.

## Decisions

- **Modes are arrow skips of one diagram.**

  | Mode | Proposals | Refactor | Re-reviews |
  |---|---|---|---|
  | Max | simplify + alternative | yes | up to 3 |
  | Balanced | simplify + alternative | above about 100 lines | up to 2 |
  | POC | simplify only | one quick pass | 1, blockers only fixed |
  | Trivial | none, plan inline | no | 0, one quick review with security |

  Every mode keeps the quick security review, the blocker arrows, fact-gap
  research and one final small fix after the last review. The table also rules
  a re-plan from a blocker. `instructions/agent.md` no longer counts steps per
  mode: the table is the one source.
- **A worker only stops; the engineer triages.** An implementer, refactorer
  or fixer that hits a blocking question the repo, brief and plan
  do not settle stops at once. It commits and pushes its work as a normal
  commit, with `Remaining: ...` in the body, and hands back
  `NEEDS_DECISION <question>` with evidence. No new status name. The engineer
  holds the goals and the user's answers, so it picks the kind: answered, fact
  (research, delta plan, simplify, resume, no user question), decision (back
  to Ctx, proposals, ask) or scope (this PR, follow-up or drop). This follows
  A2A's single `input-required` task state
  (https://a2a-protocol.org/latest/specification/) and issue triage, where the
  reporter files and the triager labels.
- **Only the lead spawns researchers.** Subagents cannot ask the user
  (https://code.claude.com/docs/en/sub-agents), so asking on demand is a
  hand-back. Trivial may spawn one small researcher for a fact gap and stays
  Trivial.
- **The engineer drives the review loop.** A fresh review-lead per round, a
  fixer between rounds, `--fixes <previous round's Reviewed head>`, verdicts
  carried from the latest round, one accumulating `-fixes.md` file. The cap is
  by mode, as the evaluator-optimizer pattern caps its iterations
  (https://www.anthropic.com/engineering/building-effective-agents). A re-plan
  resets the cap. A CI fix gets a `--fixes` review while rounds remain, then
  goes back to the CI wait.
- **The review-lead escalates only a wrong plan**: wrong approach, unmeetable
  requirement, new scope, or a data-model or auth redesign. Every other
  finding, security included, goes to a fixer. It finishes its review first
  and does not pass the line to its reviewers.
- **Proposals are a researcher mode** (`researcher/references/proposal.md`):
  `simplify` revises the plan, `alternative` writes another or returns the
  identity. Both cite standards with URLs and end in a MADR-style
  `Considered options` table (https://adr.github.io/madr/), pasted into the PR
  body.
- **A progress file in every mode**, so a fresh context resumes from it and
  `git log`
  (https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).
- **Hand-over is ready on green CI.** `/qa`, `/final-review` and
  `/give-feedback` are optional next steps in the ready notice; no QA gate and
  no run-app question. `/10x-engineer` matches it and drops its `qa` state.
- **Commits are kept.** A new plan adds commits on top; a revert only when the
  user asks.

## Considered options

- **The worker labels its own blocker** (`NEEDS_RESEARCH`, `NEEDS_DECISION`,
  `new scope:`). Rejected: a decision a worker files as a fact gap skips the
  user silently, and it adds a status name.
- **The review-lead runs the loop and spawns the fixer.** Rejected: the
  review-lead changes no code, and the engineer already holds the plan and the
  user, so it picks the rows.
- **A QA gate before ready.** Rejected: it held a green PR on a question the
  user can answer later, from a fresh session that does not carry this one's
  context.
- **Workers keep building around an open decision.** Rejected under the
  engineer: work built on a guess is rework. Elsewhere, `agent.md` keeps it,
  unless a brief says to stop.

## Consequences

- Every worker brief from the engineer carries the stop rule from
  `blockers.md`; roles did not change.
- The engineer pays one more turn per blocker to sort it.
- `pragmatic-review` re-reviews chain: `--fixes` takes the previous round's
  head, not the first review's.

Follow-ups, not done:

- **A programmatic state machine.** The states and arrows are prose; nothing
  checks that a run follows them.
- **Per-round review metrics in `self-improve`.** Its regex counts rounds 2 and
  on as re-reviews, not each round.
