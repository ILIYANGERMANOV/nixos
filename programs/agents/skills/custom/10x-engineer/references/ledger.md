# Ledger

`~/.10x/<run>/ledger.md`. Only you write it, and you update it before ending a
turn. It holds what GitHub cannot: CI, mergeability and review state are never
stored, you read them live.

```text
~/.10x/<run>/
  ledger.md
  briefs/<task>.md
  reports/<task>.md     the worker's: last step, head
  reports/<task>-requirements.md   the worker's, for every review
  reports/<task>-fixes.md          the worker's, for its re-review
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

| Task | Repo | Wave | Deps | Base | Quality | Trivial | QA | Heavy | Security-sensitive | Branch | PR | State | Tries | Merge-safe heads |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Pre-flight

| Tasks | Shared file or interface | Produces / consumes | Finding |
|---|---|---|---|

## Decisions

- [open] D1 <task>: <question>
- [resolved] D2 <task>: <question> - <the user's answer, when>

## Rulings

- <task>: Ruling: <what> - <why> - <what it costs if wrong>

## Held

- <task>: <a wake for a live agent's task: the review or comment URL>
```

## States

One `State` per task. The skill's steps name the moves; GitHub wins over them.

| State | Means |
|---|---|
| `queued <job>` | waits for a slot, a dependency or an answer |
| `running <job>` | that job's one agent is live |
| `ci` | waits for green on the head |
| `qa` | waits for the user's QA result |
| `review` | in the queue, or held by the Base gate |
| `merged` | terminal |
| `parked <reason>` | terminal unless the user picks retry, which clears `Tries`; the reason is required |

`<job>` is `engineer` or `fixer <what> <head>`: `rebase` or what
it fixes, and the live head at dispatch, so resume can tell whether it pushed.

An `[open]` line naming a task holds it, in whatever state it is: that is read
from Decisions, never stored. A worker that hands one back has left its slot, so
its task goes `queued`, and the answer starts it only in a free slot.

`Merge-safe heads` lists `<old sha> -> <new sha>` for each clean rebase, so the
merge loop can tie the head back to the commit the user approved.
