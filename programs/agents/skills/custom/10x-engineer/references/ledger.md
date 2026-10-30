# Ledger

`~/.10x/<run>/ledger.md`. Only you write it, and you update it before ending a
turn. It holds what GitHub cannot: CI, mergeability and review state are never
stored, you read them live.

```text
~/.10x/<run>/
  ledger.md
  briefs/<task>.md
  reports/<task>.md     the worker's pass-1 requirements and long notes
  worktrees/<task>/
```

## Format

```markdown
# Run <run>

User: <GitHub login, ask once if no repo owner shows it>
Notes: /tmp/<unique-dir>/
Breakdown confirmed: <yes, when>

## Intent

<the user's words, verbatim, never edited>

## Tasks

| Task | Repo | Wave | Deps | Base | QA | Heavy | Security-sensitive | Branch | PR | State | Tries | Worker | Last step | Security | Merge-safe heads |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Pre-flight

| Tasks | Shared file or interface | Produces / consumes | Finding |
|---|---|---|---|

## Decisions

- [open] D1 <task>: <question>
- [resolved] D2 <task>: <question> - <the user's answer, when>

## Rulings

- <task>: Ruling: <what> - <why> - <what it costs if wrong>
```

## States

One `State` per task:

| State | Means | Next |
|---|---|---|
| `queued` | waits for a slot, a dependency or an answer; with a PR, for a fixer | `running`, `parked` |
| `running` | an engineer or fixer is live | `queued`, `ci`, `parked` |
| `ci` | waits for green on the head | `qa`, `review`, `running`, `queued` |
| `qa` | waits for the user's QA result | `review`, `running`, `queued` |
| `review` | ready, in the queue, waits for approval | `merging`, `running`, `queued` |
| `merging` | approved, in the merge loop | `merged`, `review`, `running`, `queued` |
| `merged` | terminal | |
| `parked <reason>` | terminal unless the user picks retry, which clears `Tries`; the reason is required | `queued` |

An `[open]` line naming a task holds it, in whatever state it is: that is read
from Decisions, never stored. A worker that hands one back has left its slot, so
its task goes `queued`, and the answer starts it only in a free slot.

`Worker` is the job: `engineer`, or `fixer <job>` while one runs or waits
`queued`, a rebase with its `<old head>`, so resume knows what died.

`Last step` and `Security` come from each hand-back: the last finished /engineer
step and pass 1's `Security:` line. A fresh agent continues from them.

`Merge-safe heads` lists `<old sha> -> <new sha>` for each clean rebase, so the
merge loop can tie the head back to the commit the user approved.
