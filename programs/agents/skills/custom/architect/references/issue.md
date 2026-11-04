# Design issue

The body of a design issue: the user's confirmed decisions, in a form a person
reads first and `/engineer` or `/10x-engineer` plans from. This file is its only
source; no `.github/ISSUE_TEMPLATE` copies it.

Write it to a file under `/tmp/<unique-dir>/` and file it with
`gh issue create --title "<what, in the domain's words>" --body-file <file>`.
One issue per deliverable a single PR can close.

## Format

The top is for a person, in the style of `pr-description`'s What & Why: simple
words, short sentences, a visual over prose. The rest is the contract the
engineer plans from.

````markdown
## What & Why

<two or three sentences: what changes for whom, and why it is needed>

```text
<a small diagram, under ~45 characters wide: the flow or
 the shape after the change, new parts marked>
```

## Goal

<one sentence: the outcome, observable when done>

## Decisions

- <a confirmed decision> - <why, or the alternative it beat>

## Out of scope

- <what this issue does not do>

## Acceptance criteria

- [ ] <an observable check a reviewer can run or see>

## Open questions

- <what the user has not decided yet>, or `None`
````

## Rules

- **Decisions** hold only what the user confirmed in this conversation, never
  an assumption or your recommendation alone. A recommendation the user has not
  confirmed is an Open question.
- **Acceptance criteria** are observable: a behaviour, a command's result, a
  screen. Never "the code is clean".
- No section is dropped. An empty one says `None`.
