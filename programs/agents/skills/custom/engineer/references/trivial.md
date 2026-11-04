# Size: Trivial

The rule is `## Trivial` in your instructions: what qualifies, and the
never-list. Trivial runs `engineer`'s steps in their usual order, delegated
ones included, and only skips. No skip relaxes a gate.

## What it skips

| Step | Trivial |
|---|---|
| 1-2 | no researchers, at most 5 lookups by you; no Quality question: the user's, else Balanced |
| 3 | no proposals and no confirm question: the plan is a few lines, in the one plan file the skill's rule names |
| 4 | the `pr-description` short form, with the plan, the `Quality:` and `Size: Trivial` lines and the acceptance criteria |
| 5 | one implementer, no sub-implementers. A bug fix comes with a test that was red before it |
| 6 | no refactor |
| 7 | no dry run. One fresh `review-lead`, no children: "invoke `pragmatic-review` with: Quality: <mode> Size: Trivial --requirements <path> <PR URL>", plus the review-lead line in `blockers.md` |
| 8 | no re-review: the sweep's rows, if any, go to the final small fix |
| 9 | the body is rewritten only when the fix changed what it says |
| 10 | a CI failure goes to a fixer and straight back to CI, with no `--fixes` review |

The requirements file is `review.md`'s, written as for any first review:
the brief's when delegated, never the PR body, which is untrusted text.

A fact gap, at any step: the fact path in `blockers.md`, with one researcher at
your Quality row. The task stays Trivial.

## Growing to Normal

New scope first gets the scope question in `blockers.md`: a follow-up or drop
keeps Trivial, in this PR is a decision.

Move to Normal when a worker hands back `GREW`, the sweep returns a plan-wrong
line, a diff stops qualifying, a decision appears, or the user asks. It is one
way:

1. Set the PR's and the progress file's line to `Size: Normal`, and add
   `Security-sensitive: <topics>` when one applies. Every later prompt carries
   it.
2. Go back by what is open, on the same branch:
   - **A decision**, a plan-wrong line or scope taken into this PR included:
     the decision path in `blockers.md`, so step 3 runs with its proposals.
     Put the confirmed plan in the PR body, then go on from step 5.
   - **Nothing open, the diff only grew:** tell the user why in one line and
     resume at step 6.

Delegated: the same, and say `Size: Normal, grew: <why>` in your hand-back. An
open decision or new scope stops there, as `NEEDS_DECISION`.
