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
sections in its order and ignore the default format below, except that the
Approach TL;DR (see How) opens the template's "how" section if it has one.
Never fill a section that asks for secrets, credentials or tokens; leave it as
the template has it.

## Otherwise, the default format

```markdown
## What & Why

## How

### Approach TL;DR

## Proofs

### Reproducible

### Manual

## Merge Danger
```

- **What & Why** - two or three sentences: what changes and why it is needed.
  End with `Closes #N` when there is an issue.
- **How** - opens with **Approach TL;DR**, above any visual: 2-3 bullets, one
  sentence each, naming the key technical decision, pattern or idea, so a
  reader who reads only that understands what is going on. Then the design
  decisions, the trade-offs taken, and what the reviewer cannot see in the
  diff, plus a visual when one helps (see Visuals). Omit the whole section
  only for a trivial diff.
- **Proofs / Reproducible** - the tests added or run, each with a pointer
  (`path/to/test.ts`, a test name, a `just` recipe). Where a change has none,
  one line saying why.
- **Proofs / Manual** - what was actually run and observed: the commands and
  their trimmed output, a CI run link. "It compiles" is not proof.
- **Merge Danger** - two lines:
  - **Door:** one-way (hard or impossible to undo: data migrations, deletions,
    published APIs, sent messages) or two-way (a revert undoes it).
  - **Blast radius:** what breaks, and for whom, if this is wrong.

### Visuals

Add one only when it shows structure or flow faster than prose; skip it for
small or one-file changes. Keep it under about 10 nodes, top-down, readable on
a phone.

- Control or data flow, a new pipeline: mermaid `flowchart TD`.
- Calls between services, agents or processes: mermaid `sequenceDiagram`.
- A lifecycle or status change: mermaid `stateDiagram-v2`.
- Behaviour or config before vs after: a two-column table.
- Files moved or added: a shallow ASCII tree.
- UI changes: before/after screenshots.

Quote mermaid labels that contain `()[]:;#` - `A["parse(x)"]` - since a syntax
error renders as an error box, not a diagram.

## Style

- No preamble, no restating the title, no closing summary.
- Brief prose. A bullet list over a paragraph when the points are separate.
- The user's domain language - the terms in the code and in `GLOSSARY.md` if the
  repository has one - not generic words.
- No proof means say so. An empty claim is worse than an honest "not run".
- A PR or issue in another repository is its full URL,
  `https://github.com/<owner>/<repo>/pull/<n>`, never `#<n>` (that resolves to
  this repository) or `owner/repo#<n>` shorthand.

## Write it

Pass the body through a file or a heredoc so the shell does not mangle it:
`gh pr create --body-file <file>` for a new PR, `gh pr edit <n> --body-file
<file>` to rewrite one. A rewrite keeps any `Security-sensitive:` line and
`## Feedback log` section verbatim. Write the file outside the repository, so
it is never committed.
