## Quality table

An agent may raise or lower a subtask's Quality. Only this table changes a
step by mode: a skill reads its row for what, its text how.

| Step | POC | Balanced | Max |
|---|---|---|---|
| Researchers | 1 for all, 8 calls, notes past the hand-back limit | up to 3, 15 calls, notes | one per group, 30 calls, notes, top 5 facts re-checked |
| Implement | one implementer, one happy-path proof as its test | as planned | as planned |
| Refactor | above about 100 changed lines, quick: items 1-3, no `tests.md` | above about 100 changed lines | always |
| Skill dry run | never | new or rewritten skill | any skill change |
| Review agents | one breaker | blockers; house rules, tests where they apply; up to 2 requirement groups | all, one per group |
| Re-reviews | up to 2, blockers and Not met fixed only | up to 3 | up to 5 |
| Full review of a fix to | data model, auth | data model, auth | interface, data model, auth |
| Large fix widens on | rewritten history | rewritten history | history, size, file count |
| DEEP security | never | where tier or requirement says | where tier or requirement says |
| Result | draft labelled `POC`, not merge-ready | merge-ready | merge-ready |

Changed lines are additions plus deletions (`gh pr view --json
additions,deletions`), generated lockfiles aside.
