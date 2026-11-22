---
name: pr-description
description: Writes a short pull request description that any engineer can understand in a minute - what and why with an optional focus visual, and everything else (how, proof, decisions made without the user, QA) in collapsed sections. Stays within the visible-line budget, measured by a script. Simple words, short sentences, no file-by-file walkthrough. Fills the repository's own PR template when it has one. Use before opening a PR with `gh pr create`, when writing or updating a PR description, to add its visuals (row V0) or to simplify one (row S0).
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
- What was observed that CI cannot show, and what it printed. Only what you or
  a subagent really ran in this session.

## Rule 1: the repository's template wins

Look for a PR template: `.github/pull_request_template.md`,
`.github/PULL_REQUEST_TEMPLATE.md`, the same names at the repository root or in
`docs/`, or a `PULL_REQUEST_TEMPLATE/` directory. If one exists, fill in its
sections in its order and ignore the default format below, except that the How
paragraph and the focus visual open the template's "how" section if it has
one, and the collapsed blocks and the bottom line close the body. The Style
rules and the budget still apply inside a template. Never fill a section that
asks for secrets, credentials, tokens or what CI already shows; leave it as
the template has it.

## Otherwise, the default format

Only `## What & Why` and its focus visual are visible. Everything else sits
in a collapsed `<details>` block whose summary says what is inside, or is
dropped. Row R0 (describe) writes the prose only. Row V0 adds the visuals,
the usage snippet among them.

````markdown
## What & Why

<2-3 short sentences: what it adds and why.> Closes #N

<focus visual: a diagram, code or a table, added by row V0>

<details><summary>How</summary>

<One paragraph: what happens under the hood, in the order it happens.>
1. **<path A>** - <when it acts>
2. **<path B>** - <when it acts>

<other visuals, added by row V0>

```<lang>
// usage, added by row V0: short, made-up content that shows the API's range
```

- <at most 3 bullets for what the visuals cannot show: fallbacks, overrides>

</details>

<details><summary>Proof</summary>

<commands run, output seen, screenshots>

</details>

<details><summary>Decided without you</summary>

<each ruling made without asking the user, one why each>

</details>

<details><summary>Skipped edge cases</summary>

<each rare edge case left unhandled, with why it was skipped>

</details>

<details><summary>After merge</summary>

<steps to take once it lands>

</details>

<details><summary>Follow-ups</summary>

<each follow-up, with its reason>

</details>

<details><summary>Feedback log</summary>

<the user's feedback, verbatim>

</details>

<details><summary>QA: <verdict> ...</summary>

<written by qa>

</details>

Security-sensitive: <topics>
````

- **What & Why** - no comma chains, no `Label: a, "x" vs "y"` fragments.
  Concise beats friendly: do not pad it.
- **How** - the numbered paths only when there are several. The snippet only
  when there is an API or a call site to show, with no internal constants the
  reader must look up. Omit How when What & Why already covers it.
- **Proof** - only what was driven and observed that CI cannot show: the
  commands run, their trimmed output, screenshots. Omit when there is none.
- **Decided without you** - only the rulings the agent made without asking
  the user, one "why" each. Omit when there are none.
- **Skipped edge cases** - each rare edge case the code leaves unhandled,
  with why it was skipped. Omit when there are none.
- **After merge**, **Follow-ups** (each with its reason), **Feedback log**,
  **QA** - only when they have content. QA stays last: `qa` writes it. QA on
  an older head says so in its summary: `(on <short sha>, before <change>)`.
- **Bottom line** - `Security-sensitive: <topics>` only when set. Otherwise
  no bottom line.
- **Drop** - rename tables, acceptance-criteria checklists and considered
  options (they live in the plan), test lists, "found in review / QA" lists,
  internal ids (projects, deployments, dashboards), general out-of-scope
  lists (they live in the plan; a skipped edge case goes in its block), file
  names.

### Budget

At most 25 non-empty visible lines, each collapsed `<details>` counting as its
summary. Measure it, never guess:
`python3 -I ${CLAUDE_SKILL_DIR}/scripts/visible_lines.py <body.md>`.

## Style

The "Writing for people" rules in your instructions apply. On top:

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

"Writing for people" in your instructions says which visual to pick. Here
only what is special to a PR. Keep each under about 10 nodes, top-down,
readable on a phone.

- Mermaid renders on GitHub. Any type fits where it shows the change best,
  such as `flowchart TD`, `sequenceDiagram` or `stateDiagram-v2`.
- UI changes: before/after screenshots, in Proof.

Quote mermaid labels that contain `()[]:;#` - `A["parse(x)"]` - since a syntax
error renders as an error box, not a diagram. A label like `"<Component />"`,
raw or `&lt;`-escaped, renders as an empty node on GitHub: write a plain label
such as `"Slot component"`.

A `<details>` block needs a blank line after `</summary>` and before
`</details>`. Without them the markdown inside renders raw (CommonMark 0.31.2,
section 4.6).

## Write it

Pass the body through a file so the shell does not mangle it. Row R0 writes
it with `gh pr create --body-file <file>` for a new PR, or `gh pr edit <n>
--body-file <file>` for an existing one, so rows V0 and S0 always edit. Write
the file outside the repository, so it is never committed. A rewrite keeps
the shape, the budget and the bottom line. It keeps each visual, except one
that repeats another or shows nothing new. The focus visual stays visible.
The Feedback log stays verbatim. Every open Follow-up, the Skipped edge cases
and the QA block stay collapsed, never
dropped. An old body's visible `## Feedback log`, `## Follow-ups` or
`## QA` moves into its `<details>` block.

## Visual (row V0)

A fixer adds the visuals to the prose that row R0 wrote:

1. Read the body and the diff index.
2. Pick 0 or more visuals as "Writing for people" says. Pick from what the
   diff shows, never invent.
3. Put the focus one right after What & Why, the others inside How.
4. `gh pr edit <n> --body-file <file>`.

## Simplify (row S0)

A fresh fixer with no session history reads the body the way a reviewer does.
Edit the current body in place:

1. Read the diff index and the plan, if one exists. Write the core data flow
   in 3 sentences.
2. Rewrite the body to the shape and the visible-line budget above.
3. Check the 3 sentences can be read off the visible part, What & Why plus
   the focus visual. If not, fix the visible part, not the collapsed blocks.
4. Run `visible_lines.py` on the body file: it must stay within the budget.
5. `gh pr edit <n> --body-file <file>`.
6. End your hand-back with the line `Simplified: <head sha>`.
