---
name: pr-description
description: Writes a pull request description that a reviewer can trust - what and why, how, the proof that it works, and how dangerous the merge is. Fills the repository's own PR template when it has one. Use before opening a PR with `gh pr create`, or when writing or updating a PR description.
---

# PR description

A PR description exists so the reviewer can judge the change without
reconstructing it. Write it from facts, keep it brief, and never claim proof
that was not run.

## Gather the facts first

- The diff against the merge-base, not against a moving `main`:
  `git diff $(git merge-base HEAD origin/main)`.
- The commits: `git log --oneline <merge-base>..HEAD`.
- The issue it closes, if the branch, the commits or the conversation name one.
- What was actually run - tests, commands, CI - and what it printed. Only what
  you or a subagent really ran in this session, or a CI run you can link.

## Rule 1: the repository's template wins

Look for a PR template: `.github/pull_request_template.md`,
`.github/PULL_REQUEST_TEMPLATE.md`, the same names at the repository root or in
`docs/`, or a `PULL_REQUEST_TEMPLATE/` directory. If one exists, fill in its
sections in its order and ignore the default format below. Never fill a section
that asks for secrets, credentials or tokens; leave it as the template has it.

## Otherwise, the default format

```markdown
## What & Why

## How

## Proofs

### Reproducible

### Manual

## Merge Danger
```

- **What & Why** - two or three sentences: what changes and why it is needed.
  End with `Closes #N` when there is an issue.
- **How** - the design decisions, the trade-offs taken, and what the reviewer
  cannot see in the diff. Include the smallest visual that makes the point
  clear (a diff-sketch, a call tree, a shallow file tree or a mermaid diagram),
  and only when it helps more than a sentence. Omit the whole section when the diff
  speaks for itself.
- **Proofs / Reproducible** - the tests added or run, each with a pointer
  (`path/to/test.ts`, a test name, a `just` recipe). Where a change has none,
  one line saying why.
- **Proofs / Manual** - what was actually run and observed: the commands and
  their trimmed output, a CI run link. "It compiles" is not proof.
- **Merge Danger** - two lines:
  - **Door:** one-way (hard or impossible to undo: data migrations, deletions,
    published APIs, sent messages) or two-way (a revert undoes it).
  - **Blast radius:** what breaks, and for whom, if this is wrong.

## Style

- No preamble, no restating the title, no closing summary.
- Brief prose. A bullet list over a paragraph when the points are separate.
- The user's domain language - the terms in the code and in `GLOSSARY.md` if the
  repository has one - not generic words.
- No proof means say so. An empty claim is worse than an honest "not run".

## Write it

Pass the body through a file or a heredoc so the shell does not mangle it:
`gh pr create --body-file <file>` for a new PR, `gh pr edit <n> --body-file
<file>` to rewrite one. Write the file outside the repository, so it is never
committed.
