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

| Task | Repo | Wave | Deps | Base | QA | Heavy | Security-sensitive | Branch | PR | State | Tries | Worker | Last step | Head | Security | Merge-safe heads |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

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
| `queued` | waits for a slot or a dependency; with a PR, for a rebase fixer | `running` |
| `running` | an engineer or fixer is live | `decision`, `ci`, `parked` |
| `decision` | an open decision holds it | `running`, `parked` |
| `ci` | waits for green on the head | `qa`, `review`, `running`, `queued` |
| `qa` | waits for the user's QA result | `review`, `decision` |
| `review` | ready, in the queue, waits for approval | `merging`, `running`, `queued` |
| `merging` | approved, in the merge loop | `merged`, `review`, `running`, `queued` |
| `merged` | terminal | |
| `parked <reason>` | terminal; the reason is required | |

`Last step`, `Head` and `Security` come from each hand-back: the last finished
/engineer step, the head SHA and pass 1's `Security:` line. A fresh agent
continues from them.

`Merge-safe heads` lists `<old sha> -> <new sha>` for each clean rebase, so the
merge loop can tie the head back to the commit the user approved.
