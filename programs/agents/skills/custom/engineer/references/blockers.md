# Blockers and the progress file

A worker is an implementer, refactorer, fixer or review-lead you spawn. A
worker never asks the user and never researches past the repo: it stops and
hands the question back. You sort it. Only you spawn researchers.

## The stop rule

Paste this paragraph into every worker brief, the review-lead's included:

> A question that blocks your work and that the repo, this brief and the plan
> do not settle: stop at once. Commit and push the work you have, if any, as a
> normal commit that builds, with no WIP marker and
> `Remaining: <what is left>` in its body.
> Start your hand-back with `NEEDS_DECISION <question>`, then that commit, what
> you tried and the evidence paths. Spawn no researcher. Pass this paragraph to
> any agent you spawn, and relay its `NEEDS_DECISION` as-is.

A review-lead brief adds:

> The plan is wrong when a finding shows a wrong approach, a requirement that
> cannot be met, scope the plan does not hold, or a data-model or auth
> redesign. Then the first line of your return is
> `NEEDS_DECISION plan wrong: <finding>`, before the usual report. Every other
> finding, security included, goes in the table as usual.

A question that does not block stays in the hand-back's prose, as the role
says. A refactorer's proposals are not blockers: step 6 asks about them.

## Triage

Read the question and its evidence, then pick exactly one row. Log it in the
progress file.

| You find | Kind | Arrow |
|---|---|---|
| The plan, the notes or a user answer already settle it | answered | resume with the answer |
| A fact nobody has looked up | fact | the fact path |
| A choice the user owns, or the plan is wrong | decision | the decision path |
| Work the plan does not hold | scope | the scope question |

**Resume.** A worker that handed back is gone. Spawn a fresh worker of the same
role with its brief, the answer, and "continue from commit `<sha>`: its body
says what remains". Commits are never reverted unless the user asks.

**Fact path.** No user question.

1. Researchers per `## Callers` in the researcher skill, the question in their
   prompt. Trivial: one small researcher briefed `Quality: <mode>, Trivial`,
   and the task stays Trivial.
2. Write a delta plan: what the facts change in the plan.
3. Run the mode's simplify pass on it (the skill's mode table; Trivial has none).
4. Record the fact and the delta in the PR body, then resume.

Research or a simplify pass that turns up a choice the user owns, or changes
the approach, moves the item to the decision path.

**Decision path.**

1. Back to Ctx: steps 1 and 2 for this question only. Research what it needs,
   then ask the user.
2. Step 3 at the current mode: a new plan, its proposals, and the ask. A
   decision in Trivial leaves the track first (`trivial.md`), so step 3 runs at
   the user's Quality, Balanced if they named none.
3. Write the chosen plan and its `Considered options` into the PR body.
4. Resume at step 5 on the same branch. Existing commits stay; the new plan
   adds commits on top. Its review starts again at round 1, so the cap resets.

**Scope question.** One `AskUserQuestion`: in this PR, a follow-up, or drop.
In this PR: the decision path. A follow-up: add it to `## Follow-ups`. Either
of the last two: resume without it.

Delegated: `## Delegated` says which rows you settle inside.

## The progress file

From step 4, beside `requirements.md`:
`/tmp/engineer-<owner>-<repo>-<PR>/report.md`. Delegated: the brief's report
file. Rewrite it after each step, round and blocker. A fresh context resumes
from it and `git log`.

```markdown
Step: <last finished step>
Head: <sha>
Quality: <mode>[, Trivial]
Review round: <n>/<cap>
Reviewed head: <latest round's sha>
Blockers:
- <question> - <answered | fact | decision | scope> - <open | done: answer>
Log:
- <research done, decision made, row recorded>
```

The PR-body updates above are written from this file.
