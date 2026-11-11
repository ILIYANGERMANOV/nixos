# Blockers

A worker is an implementer, refactorer, fixer or review-lead you spawn. A
worker never asks the user and never researches past the repo: it stops and
hands the question back. You sort it. Only you spawn researchers.

## The stop rule

Paste this paragraph into every implementer, refactorer and fixer brief:

> A question that blocks your work and that the repo, this brief and the plan
> do not settle, or choosing differently from a decision the plan states:
> stop at once. Commit and push the work you have, if any, as a
> normal commit with no WIP marker and `Remaining: <what is left>` in its
> body, plus `(does not build yet)` when it does not build.
> Start your hand-back with `NEEDS_DECISION <question>`, then that commit, what
> you tried and the evidence paths. Spawn no researcher.
> On `Size: Trivial`, work bigger than briefed is `GREW <why>`: stop the same
> way, after committing and pushing what you have, and start your hand-back
> with that line. With a `NEEDS_DECISION`, that line comes first and `GREW`
> on the next.

A review-lead brief, the Trivial sweep's included, gets this line instead, and
passes nothing of it to its reviewers:

> The plan is wrong when a finding shows a wrong approach, a requirement that
> cannot be met, scope the plan does not hold, or a data-model or auth
> redesign. Do not stop early: finish the review, then make
> `NEEDS_DECISION plan wrong: <finding>` the first line of your return, before
> the usual report. Every other finding, security included, goes in the table
> as usual.

A question that does not block stays in the hand-back's prose, as the role
says, and you still triage it below. A refactorer's proposals are not
blockers: step 6 asks about them.

## Triage

Read the question and its evidence, then pick exactly one row. The hook
records a `NEEDS_DECISION` hand-back untriaged, a `plan wrong:` or `stuck:`
one as a decision; `state next` advises the rest. Record the row with
`state record blocked <kind> <role> <question>`, a prose question's too, and
its answer with `state record resolved`. A decision's answer that changes the
plan is a re-plan, `state record planned`, right after it; one that does not
resumes the step it came from. Before `READY` or
`gh pr ready`, every open decision, a hand-back's prose question included, has
its row and is done; none is handed on as prose in the PR body or a hand-back.

The user's answer to the stuck guard is a decision, recorded as `state next`
says: the decision path, a dropped row too. The same row or check in a later
round is stuck again.

| You find | Kind | Arrow |
|---|---|---|
| The plan, the notes or a user answer already settle it | answered | resume with the answer |
| A fact nobody has looked up | fact | the fact path |
| A choice the user owns, or the plan is wrong | decision | the decision path |
| Work the plan does not hold | scope | the scope question |

**Resume.** A worker that handed back is gone. Spawn a fresh worker of the same
role with its brief, the answer, the delta plan when there is one, and
"continue from commit `<sha>`: its body says what remains; when it says it
does not build, make it build first". Commits are never reverted unless the
user asks. The same question back in 2 rounds in a row, whatever the commit,
trips the skill's stuck guard.

**Fact path.** No user question.

1. One researcher per fact gap, prompt per `## Callers` in the researcher
   skill with the question in it. It does not count against step 1's Agents.
2. Write a delta plan: what the facts change in the plan.
3. Run your Quality row's simplify pass on it; `Size: Trivial` skips it.
4. Record the fact and the delta in the PR body, then resume.

Research or a simplify pass that turns up a choice the user owns, or changes
the approach, moves the item to the decision path. It changes the approach
when it changes a goal, a decision or an interface.

**Decision path.**

1. Back to Ctx: steps 1 and 2 for this question only. Research what it needs,
   then ask the user what is still open, never what they just answered. No
   plan change: `state record resolved` resumes where you were, with no steps 2-4.
2. Step 3 at the current Quality, with no Quality question: a new plan, its
   proposals, and the ask. A decision on `Size: Trivial` moves it to Normal
   first (`trivial.md`).
3. Write the chosen plan and its `Considered options` into the PR body.
4. Resume at step 5 on the same branch. Existing commits stay; the new plan
   adds commits on top. Its review starts again at round 1, so the re-review
   cap resets; the stuck guard does not.

**Scope question.** One `AskUserQuestion`: in this PR, a follow-up, or drop.
In this PR: the decision path. A follow-up: add it to `## Follow-ups`. Either
of the last two: resume without it.

Delegated: `## Delegated` says which rows you settle inside.
