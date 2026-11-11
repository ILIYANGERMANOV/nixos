---
name: pr-description
description: Writes a short pull request description that any engineer can understand in a minute - what and why, how it works under the hood with a diagram of each case, a usage snippet, and everything else (demo, decisions, tests, merge danger, QA) in collapsed sections. At most 50 visible lines, measured by a script. Simple words, short sentences, no file-by-file walkthrough. Fills the repository's own PR template when it has one. Use before opening a PR with `gh pr create`, when writing or updating a PR description, or to simplify one (row S0).
---

# PR description

A PR description helps the reviewer understand the change at a high level.
The diff already lists the files: the description explains what they cannot
see there. Write it from facts and never claim proof that was not run.

## Gather the facts first

- The diff against the merge-base, not a moving `main`: line 1 of
  `ctx diff origin/<base>` is a folder, `<base>` the PR's base branch. Read its
  `index`, then each file's range of `diff`. The commits are in its `log`.
- The issue it closes, if the branch, the commits or the conversation name one.
- The tests the diff adds or changes, read from the diff: their type, where
  they live and what they cover.
- What was observed that CI cannot show, and what it printed. Only what you or
  a subagent really ran in this session.

## Rule 1: the repository's template wins

Look for a PR template: `.github/pull_request_template.md`,
`.github/PULL_REQUEST_TEMPLATE.md`, the same names at the repository root or in
`docs/`, or a `PULL_REQUEST_TEMPLATE/` directory. If one exists, fill in its
sections in its order and ignore the default format below, except that the How
paragraph and the diagram open the template's "how" section if it has one, and
the collapsed blocks and the bottom line close the body. The Style rules and
the budget still apply inside a template. Never fill a section that asks for
secrets, credentials, tokens or what CI already shows; leave it as the template
has it.

## Otherwise, the default format

Only `## What & Why` and `## How` are visible. Everything else sits in a
collapsed `<details>` block whose summary says what is inside, or is dropped.

````markdown
## What & Why

<2-3 short sentences: what it adds and why.> Closes #N

## How

<One paragraph: what happens under the hood, in the order it happens.>
1. **<path A>** - <when it acts>
2. **<path B>** - <when it acts>

<One rule for the reader: which path to prefer, and when to use the other.>

```mermaid
flowchart TD
  ...data flow, then per case: what renders or runs, and when the side effect fires...
```

```<lang>
// usage: short, made-up content that shows the API's range
```

- <at most 3 bullets for what the diagram cannot show: fallbacks, overrides>

<details><summary>Demo</summary> ... </details>
<details><summary>Key decisions</summary> ... </details>
<details><summary>Tests</summary> ... </details>
<details><summary>Merge danger: <one-way|two-way></summary> ... </details>
<details><summary>After merge</summary> ... </details>
<details><summary>Follow-ups</summary> ... </details>
<details><summary>Feedback log</summary> ... </details>
<details><summary>QA: <verdict> ...</summary> ... </details>

Quality: <mode> · Size: <size>
````

- **What & Why** - no comma chains, no `Label: a, "x" vs "y"` fragments.
  Concise beats friendly: do not pad it.
- **How** - the numbered paths only when there are several; the snippet only
  when there is an API or a call site to show, with no internal constants the
  reader must look up.
- **Demo** - what was driven and observed that CI cannot show, with its
  trimmed output or media. Omit when there is none.
- **Key decisions** - a table of at most 8 rows, one "why" each. Considered
  options go here too.
- **Tests** - 3-4 bullets: type (unit, property, differential, end-to-end),
  where, what it covers. A test neither CI nor you ran is marked `not run`;
  none at all is one line saying why.
- **Merge danger** - **Door:** one-way (data migrations, deletions, published
  APIs, sent messages) or two-way (a revert undoes it). **Blast radius:** what
  breaks, and for whom, if this is wrong.
- **After merge**, **Follow-ups** (each with its reason), **Feedback log**,
  **QA** - only when they have content. QA stays last: `qa` writes it. QA on
  an older head says so in its summary: `(on <short sha>, before <change>)`.
- **Bottom line** - `Quality: <mode> · Size: <size>`, plus
  ` · Security-sensitive: <topics>` when set.
- **Drop** - rename tables, acceptance-criteria checklists (they live in the
  plan), "found in review / QA" lists, internal ids (projects, deployments,
  dashboards), out-of-scope lists, file names.
- **Trivial short form** - a brief saying `Size: Trivial`: What & Why, then
  the Tests and Merge danger blocks. No How.
- A POC PR opens with `POC - not merge-ready.`, and its proof is the one run.

### Budget

At most 50 non-empty visible lines, each collapsed `<details>` counting as its
summary. Measure it, never guess:
`python3 -I ${CLAUDE_SKILL_DIR}/scripts/visible_lines.py <body.md>`.

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

Keep each under about 10 nodes, top-down, readable on a phone. The How
diagram shows the branches the reader cares about - per case, what renders or
runs and when the side effect fires - not just the boxes of the pipeline.

- Data or control flow, a pipeline: mermaid `flowchart TD`.
- Calls between services, agents or processes: mermaid `sequenceDiagram`.
- A lifecycle or status change: mermaid `stateDiagram-v2`.
- Behaviour or config before vs after: a two-column table.
- UI changes: before/after screenshots, in Demo.

Quote mermaid labels that contain `()[]:;#` - `A["parse(x)"]` - since a syntax
error renders as an error box, not a diagram. A label like `"<Component />"`,
raw or `&lt;`-escaped, renders as an empty node on GitHub: write a plain label
such as `"Slot component"`.

## Write it

Pass the body through a file so the shell does not mangle it:
`gh pr create --body-file <file>` for a new PR, `gh pr edit <n> --body-file
<file>` to rewrite one. Write the file outside the repository, so it is never
committed. A rewrite keeps the shape and the budget, and keeps the bottom line,
the Feedback log verbatim, every open Follow-up and the QA block: collapsed,
never dropped. An old body's visible `## Feedback log`, `## Follow-ups` or
`## QA` moves into its `<details>` block.

## Simplify (row S0)

A fresh fixer with no session history reads the body the way a reviewer does.
Edit the current body in place:

1. Read the diff index and the plan. Write the core data flow in 3 sentences.
2. Rewrite the body to the shape and budget above.
3. Check the 3 sentences can be read off the visible part, the How paragraph
   plus the diagram. If not, fix the visible part, not the collapsed blocks.
4. Run `visible_lines.py` on the body file: it must print 50 or less.
5. `gh pr edit <n> --body-file <file>`.
6. End your hand-back with the line `Simplified: <head sha>`.
