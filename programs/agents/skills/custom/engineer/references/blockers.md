# Questions and blockers

A worker is an implementer, refactorer, fixer or review-lead you spawn. A
worker never asks and never researches past the repo: it stops and hands the
question back. Only you spawn researchers.

## The stop rule

`state brief` puts this paragraph into every implementer, refactorer and fixer
brief:

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

A question that does not block stays in the hand-back's prose; it gets a kind
all the same. A refactorer's proposals are not blockers: Build asks about them.

## Who answers

Every question has a kind; the kind and the role decide who answers. Your row
is `engineer`. `Security` is above every other kind: raise a question to it
(`state rule` or `state forward` with `--raise security`), never lower one.

| Kind | worker | engineer | 10x | user |
|---|---|---|---|---|
| Fact | forwards | answers | answers | never asked |
| Pick | forwards | answers | answers | answers |
| Design | forwards | forwards | answers if it passes the rule test | answers |
| Scope | forwards | forwards | answers if it passes the rule test | answers |
| Confirm | forwards | answers if the task is `Size: Trivial` | answers if the task plan fits the confirmed breakdown | answers |
| Security | forwards | forwards | answers if the user already answered it, or it is obvious | answers |
| Stuck | forwards | forwards | answers if no retry was spent on it yet | answers |

## Triage

A worker's `NEEDS_DECISION` with no kind is recorded as `triage:`, with
`fix: state ask --kind <kind> --from <role> <question>`. Read the question and
its evidence, give it one kind, run that line, then the Ask rule:

| You find | Kind | Then |
|---|---|---|
| The plan, the notes or an answer already settle it | its own | `state rule`, the source as `--why`, then resume |
| A fact nobody has looked up | `Fact` | the fact path |
| Work the plan does not hold | `Scope` | in this PR is a re-plan; a follow-up goes in `## Follow-ups`; either of the last two resumes without it |
| A choice the plan does not settle | `Design`, `Confirm` or `Security` | the answer that changes the plan is a re-plan; else resume |
| The same row or check 2 rounds in a row | `Stuck` | as for `Design`; a dropped row too |

Before `ready`, or a `READY` hand-back, `state pending` is empty: no question
goes on as prose in the PR body or a hand-back.

**Resume.** A worker that handed back is gone. Spawn a fresh worker of the
same role with its brief, the answer, the delta plan when there is one, and
"continue from commit `<sha>`: its body says what remains; when it says it
does not build, make it build first". Commits are never reverted unless the
user asks. The same question back in 2 rounds in a row, whatever the commit,
trips the stuck guard.

**Fact path.** One researcher per fact gap, prompted per `## Callers` in the
researcher skill with the question in it; it does not count against
Gather's. Write a delta plan: what the facts change. Run your Quality row's
simplify pass on it, `Size: Trivial` aside. Record the fact and the delta in
the PR body, `state rule` the question, then resume. A fact that changes a
goal, a decision or an interface, or opens a choice someone else owns, is a
new question of that kind.

**Re-plan.** An answer that changes a goal, a decision or an interface, or a
review-lead's `plan wrong:` line you agree with: `state stop replan <why>`,
then do what it prints. On `STOP replan`, start a new run in a fresh notes
directory, `state init --notes <dir>-replan-<n>`, on the same branch and PR,
at the same Quality: Gather for the open question only, never re-asking what
was just answered, then Propose and confirm. A `Size: Trivial` task moves to
Normal first (`trivial.md`). The new plan and its `Considered options` go into
the PR body. Existing commits stay and the new plan adds commits on top; its
review starts again at round 1, so the re-review cap resets. The stuck guard
does not.
