## Fuel table

An agent may raise or lower a subtask's Fuel. Only this table changes a step
by Fuel: a skill reads its row for what, its text how.

| Step | Low | Balanced | Max |
|---|---|---|---|
| Researchers | 1 for all, 8 calls, notes past the hand-back limit | up to 3, 15 calls, notes | one per group, 30 calls, notes, top 5 facts re-checked |
| Skippable when trivial | `research`, `simplify_plan`, `refactor` | none | none |
| Refactor | unless trivial, quick: items 1-3, no `tests.md` | above about 100 changed lines | always |
| Skill dry run | new or rewritten skill | new or rewritten skill | any skill change |
| Review agents | the Low sweep, else as Balanced | blockers; house rules, tests where they apply; up to 2 requirement groups | all, one per group |
| Re-reviews | up to 1, blockers and Not met fixed only | up to 3 | up to 5 |
| Full review of a fix to | data model, auth | data model, auth | interface, data model, auth |
| Large fix widens on | rewritten history | rewritten history | history, size, file count |
| DEEP security | where tier or requirement says | where tier or requirement says | where tier or requirement says |

Every Fuel asks Confirm and ends merge-ready. A task is trivial when it is
clear, a revert undoes it, it is about 100 changed lines, and it touches no
auth, CI, database, secrets, deploy, data model, or skill and instruction
beyond a typo. Skip a step only then, by the record `state next` prints.

Changed lines are additions plus deletions (`gh pr view --json
additions,deletions`), generated lockfiles aside.
