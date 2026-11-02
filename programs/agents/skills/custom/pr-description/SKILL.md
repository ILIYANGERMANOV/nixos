---
name: pr-description
description: Writes a short pull request description that a reviewer can understand and trust - what and why, the data flow as a diagram, the architecture and patterns, the proof that it works, and how dangerous the merge is. Simple words, short sentences, visuals over prose; no file-by-file walkthrough. Fills the repository's own PR template when it has one. Use before opening a PR with `gh pr create`, or when writing or updating a PR description.
---

# PR description

A PR description helps the reviewer understand the change at a high level.
The diff already lists the files: the description explains what they cannot
see there. Write it from facts and never claim proof that was not run.

## Gather the facts first

- The diff against the merge-base, not against a moving `main`:
  `git diff $(git merge-base HEAD origin/main)`.
- The commits: `git log --oneline <merge-base>..HEAD`.
- The issue it closes, if the branch, the commits or the conversation name one.
- The tests the diff adds or changes, read from the diff: their type, where
  they live and what they cover.
- What was observed that CI cannot show, and what it printed. Only what you or
  a subagent really ran in this session.

## Rule 1: the repository's template wins

Look for a PR template: `.github/pull_request_template.md`,
`.github/PULL_REQUEST_TEMPLATE.md`, the same names at the repository root or in
`docs/`, or a `PULL_REQUEST_TEMPLATE/` directory. If one exists, fill in its
sections in its order and ignore the default format below, except that the
Approach TL;DR and the data flow open the template's "how" section if it has
one, and `## Follow-ups` closes the body when it has entries. The Style rules
still apply inside a template. Never fill a section that asks for secrets,
credentials, tokens or what CI already shows; leave it as the template has it.

## Otherwise, the default format

```markdown
## What & Why

## How

### Approach TL;DR

### Data flow

### Architecture

## Proofs

### Reproducible

### Manual

## Merge Danger

## Follow-ups
```

- **What & Why** - two or three sentences: what changes and why it is needed.
  End with `Closes #N` when there is an issue.
- **Approach TL;DR** - 2-3 bullets, one sentence each, naming the key idea, so
  a reader who reads only that understands what is going on.
- **Data flow** - the most important part. A diagram of how data or control
  moves through the change, from input to output (see Visuals). Mark what is
  new or changed.
- **Architecture** - a few bullets: the patterns used, where the new pieces
  sit, the trade-offs taken, and what the reviewer cannot see in the diff.
  Never a file-by-file walkthrough; name a file only when the reader must
  look at it.
- **Trivial short form** - a brief saying `Trivial`, or a diff that qualifies by
  the Trivial rule in your instructions, read from the facts above, unless the
  brief says `not Trivial`: What & Why, Proofs and Merge Danger. Omit the whole
  How section only here.
- **Proofs / Reproducible** - each test added or changed: its type (unit,
  property, differential, end-to-end), where it lives and what it covers. Where
  a change has none, one line saying why. A test neither CI nor you ran is
  marked `not run`.
- **Proofs / Manual** - what was driven and observed that CI cannot show, with
  its trimmed output: a QA run, a real host, a scratch-copy experiment,
  before/after numbers. Omit it when there is none.
- **Merge Danger** - two lines:
  - **Door:** one-way (hard or impossible to undo: data migrations, deletions,
    published APIs, sent messages) or two-way (a revert undoes it).
  - **Blast radius:** what breaks, and for whom, if this is wrong.
- **Follow-ups** - one bullet per known item this PR leaves undone, each with
  its reason. Omit the section when there are none.

A POC PR opens with `POC - not merge-ready.`, and its proof is the one run.

## Style

The "Writing for people" rules in your instructions apply: simple words, short
sentences, visuals over prose. On top:

- The visuals carry the explanation; prose only fills the gaps.
- No preamble, no restating the title, no closing summary.
- The user's domain language - the terms in the code and in `GLOSSARY.md` if
  the repository has one - not generic words.
- No proof means say so. An empty claim is worse than an honest "not run".
- Never write what CI already shows: local `just` runs, "lint passes", "tests
  pass", "it compiles", CI run links.
- A PR or issue in another repository is its full URL,
  `https://github.com/<owner>/<repo>/pull/<n>`, never `#<n>` (that resolves to
  this repository) or `owner/repo#<n>` shorthand.

### Visuals

Keep each under about 10 nodes, top-down, readable on a phone.

- Data or control flow, a pipeline: mermaid `flowchart TD`.
- Calls between services, agents or processes: mermaid `sequenceDiagram`.
- A lifecycle or status change: mermaid `stateDiagram-v2`.
- Behaviour or config before vs after: a two-column table.
- An algorithm or a decision: a few lines of pseudo-code.
- UI changes: before/after screenshots.

Quote mermaid labels that contain `()[]:;#` - `A["parse(x)"]` - since a syntax
error renders as an error box, not a diagram.

## Write it

Pass the body through a file or a heredoc so the shell does not mangle it:
`gh pr create --body-file <file>` for a new PR, `gh pr edit <n> --body-file
<file>` to rewrite one. A rewrite keeps any `Quality:` or `Security-sensitive:` line and
`## Feedback log` section verbatim, and every open `## Follow-ups` item. Write the file outside the repository, so
it is never committed.
