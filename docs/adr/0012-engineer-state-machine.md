# The engineer flow is a state machine where agents research and ask on demand

`/engineer` ran a fixed lifecycle: research and ask up front, then build,
review once, fix once, and hand over. A question a worker hit mid-build had no
path back to the user, and the review loop stopped after one re-review in
every mode. Now each step is a state with named arrows, a Quality mode only
skips arrows, and any worker can hand a blocking question back to the
engineer, who sorts it.

Amended by #318: two knobs (Quality and Size) defined once, a stuck guard
instead of per-loop caps, and rules against plan drift. This text describes the
current flow; the old per-mode table and the `, Trivial` suffix are gone.

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

- **Two knobs skip arrows of one diagram; neither adds any.**
  - **Quality** (`POC`, `Balanced`, `Max`) is the user's: how much effort the
    work gets. Its only definition is the table in
    `programs/agents/instructions/topics/quality.md`, one row per step. A skill
    reads its row for what runs; its own text says how. The table reaches only
    the lead and the roles that branch on it.
  - **Size** (`Size: Trivial|Normal`, its own brief line) is the engineer's
    alone, set once. Trivial is a skip table on the normal step order
    (`engineer/references/trivial.md`). A worker never switches it: it hands
    back `GREW <why>` and the engineer moves the task to Normal for good. A
    delegated engineer owns Size and reports `Size: Normal, grew: <why>`.
  - `lib/passes/modes.nix`, in the `agents` check, fails the build when a mode
    row, a `<mode>:` branch or a Trivial switch appears outside the table and
    its allow-list, so the rules cannot drift back into many files.

  Every mode keeps the quick security review, the blocker arrows, fact-gap
  research and one final small fix after the last review. A re-plan from a
  blocker follows the same table.
- **A worker only stops; the engineer triages.** An implementer, refactorer
  or fixer that hits a blocking question the repo, brief and plan
  do not settle stops at once. It commits and pushes its work as a normal
  commit, with `Remaining: ...` in the body, and hands back
  `NEEDS_DECISION <question>` with evidence. Choosing differently from a
  decision the plan states is such a question too. The engineer
  holds the goals and the user's answers, so it picks the kind: answered, fact
  (research, delta plan, simplify, resume, no user question), decision (back
  to Ctx, proposals, ask) or scope (this PR, follow-up or drop). This follows
  A2A's single `input-required` task state
  (https://a2a-protocol.org/latest/specification/) and issue triage, where the
  reporter files and the triager labels.
- **Only the lead spawns researchers.** Subagents cannot ask the user
  (https://code.claude.com/docs/en/sub-agents), so asking on demand is a
  hand-back. A `Size: Trivial` task may get one small researcher for a fact
  gap and stays Trivial.
- **One plan text, passed by path.** The brief or `plan.md` is the only plan;
  no agent writes a second one. Every review, Trivial included, gets
  `--requirements <path>`, and each plan decision is a requirement. Open
  decisions are triaged before `READY` or `gh pr ready`, never handed on as
  prose. The `/engineer` dry run on nextjs-template#6 showed two plan texts
  drifting into tech debt that no review could see.
- **The engineer drives the review loop.** A fresh review-lead per round, a
  fixer between rounds, `--fixes <previous round's Reviewed head>`, verdicts
  carried from the latest round, one accumulating `-fixes.md` file. The
  Quality row's Re-reviews count the normal rounds, as the evaluator-optimizer
  pattern bounds its iterations
  (https://www.anthropic.com/engineering/building-effective-agents). A CI fix
  gets a `--fixes` review while rounds remain, then goes back to the CI wait.
- **One stuck guard, no other caps.** Quality comes first, so loops (review
  rounds, CI fixes, re-plans, blocker resumes, refactor in this PR) run while
  they make progress. The same failing check or the same review row in 2
  rounds in a row, whatever the commit, asks the user, or hands back
  `NEEDS_DECISION` when delegated. It is a circuit breaker
  (https://martinfowler.com/bliki/CircuitBreaker.html) that trips on no
  progress, and it lives once, in the engineer skill's Rules.
- **Not met is always fixed.** A requirement or plan decision a review answers
  Not met is fixed in every mode, Trivial included, and gets one `--fixes`
  review. It never goes to Follow-ups.
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

- **Hard caps per loop** (for example 2 CI fixes, 1 re-plan). Rejected: they
  stop a run that is still making progress; the stuck guard stops only one
  that is not.
- **Trivial as a fourth Quality mode, or a `, Trivial` suffix.** Rejected: it
  mixed the user's effort choice with the engineer's size judgment, and four
  skills switched it on by themselves.
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

- Every implementer, refactorer and fixer brief from the engineer carries the
  stop rule from `blockers.md`, and every review-lead brief only its plan-wrong
  line; roles did not change.
- The engineer pays one more turn per blocker to sort it.
- `pragmatic-review` re-reviews chain: `--fixes` takes the previous round's
  head, not the first review's.

Follow-ups, not done:

- **A programmatic state machine.** The states and arrows are prose; nothing
  checks that a run follows them.
- **Per-round review metrics in `self-improve`.** Its regex counts rounds 2 and
  on as re-reviews, not each round. The per-PR metrics design is in #312.
