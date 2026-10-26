---
name: pragmatic-review
description: Reviews a diff or PR like a pragmatic engineer, a fresh subagent per pass. A first review picks a risk tier (docs-only, code, sensitive) and runs blockers, regressions, house-rules and tests agents plus one per requirement, answered Met, Not met or Unverified; a sensitive diff (CI, secrets, auth, migrations, deploy) gets a DEEP security review with a CI checklist; a re-review (--fixes <sha>) checks only the fix diff. Always blocks on security (injection, RCE, leaked data, broken auth, committed secrets) and irreversible damage (destructive migrations with an unproven WHERE, unbounded deletes, irreversible side effects), plus broken code and TEMP, WIP or debug commits. Flags engineering and ui-coding rule violations, DRY included, and fake or weak tests. Findings are Major, Minor or Nit; mergeable iff no Major survives; every report says what security was checked. Drops taste and edge cases. Nothing is fixed or posted until a picker says so; a delegating agent answers it. Use before merging a PR or branch.
argument-hint: "[requirements] [PR number or URL] [--fixes <first-review head sha>]"
---

# Pragmatic Review

Answer one question: **is this diff safe to merge?** Look for real bugs and
obvious incompetence - a change so plainly wrong or dangerous that letting it
through would be negligent - and nothing else. Most healthy diffs contain
neither, and saying so is the correct outcome.

Two failures are equally bad: waving through a diff that breaks production or
leaks data, and burying one real bug under twelve opinions.

## Where this runs

- **In a fresh subagent, one per pass.** A caller such as `engineer` spawns an
  agent whose prompt is "invoke `pragmatic-review` with: <arguments>", and does
  not load this skill itself. Invoked by the user, it runs in their session.
- **Load it once.** If this text is already in your context, never invoke the
  skill again, and never read a reference twice: what you read, you hold. The
  review agents you spawn never load it - their prompts carry what they need.
- **Read a reference only in the step that names it.** References live in
  `references/` under the base directory the Skill tool reported.
- **Delegated** means another agent invoked you. You cannot ask anyone: your
  caller answers the pickers from your return, by replying to you or by acting
  on the table itself.

## Input

`$ARGUMENTS` may hold, in any order:

- **A PR** - a bare number or a `github.com/.../pull/N` URL. Without one, review
  the current branch, uncommitted work included.
- **`--fixes <sha>`** - this is a re-review of the fixes made since a first
  review whose head was `<sha>`, the `Reviewed head` line of its return. Without
  it, this is a first review.
- **Requirements** - anything else, usually a bracketed list, one per bullet or
  line; *tips* is a synonym. On a re-review the caller passes the first review's
  requirements again, plus "finding N is fixed" for each row it fixed.

Anything the user says must hold, including in a reply to your question, is a
requirement. No requirements - nothing, an empty string, `no requirements` - is
the default review; do not ask for any.

## Requirements are authoritative

A requirement comes from the engineer who wrote the code, and they know where
they are unsure. Each one is restated as a checkable statement, verified by a
requirement agent, and answered with a verdict - "I checked, it holds" included,
because silence reads as "I forgot to look". Requirements **add** scope and never
remove it: a requirement asking to skip a category is confirmed with the user
first, and never suppresses a blocker. One may lead outside the diff; what is
found there is **pre-existing** - answered, flagged, not blocking.

## You report. The pickers decide.

Before the action picker is answered, never post a review or comment, approve or
request changes, or edit, commit, push or amend anything. Every GitHub call
until then is read-only (`gh pr view`, `git fetch`). Being asked to review is
not permission to act. When another agent invoked this skill, it stands in for
the user and its answer is the instruction.

## The bar

`references/bar.md` is the bar: severity, the always-check list, what is never a
finding, refutation, and the agents' return schema. You paste it into every
agent's prompt and judge their returns at it. The verdict is mechanical:
**mergeable iff no Major survives.**

**Blockers reverse the reluctance.** Security (injection, RCE, leaked user data,
broken auth, broken crypto, hard-coded credentials, committed secret-bearing
files) and irreversible damage (destructive statements with an unproven filter,
unbounded mutations, migrations with no way back, deletions outside the
database, irreversible external effects) are always Major, and **when unsure,
reported** - the line is reversibility. A blocker must still be reachable (name
the attacker, entry point and gain, or the rows destroyed) and belong to this
diff; a pre-existing one gets one line under the table and does not block.
`references/blockers.md` is the canonical list. The risk tier picked in
`first-pass.md` sets how deep it digs: a sensitive diff - CI, secrets, auth,
migrations, deploy - gets a DEEP blockers agent with `references/ci-security.md`.

**House rules are not taste.** A diff that plainly contradicts a rule written in
`engineering` or `ui-coding`, DRY included, is a Minor finding, judged on the
rule quoted verbatim.

## The flow

- **First review:** follow `references/first-pass.md` - write the diff once,
  pick the tier, route, group the requirements, spawn, judge.
- **Re-review (`--fixes`):** follow `references/fixes.md` - one agent on the fix
  diff, unless the fixes are large.

Both end in the report below, then the pickers.

## The report

Facts first, the call last: a verdict read first anchors the reader. The order
is fixed - answered or open intent-unclear test questions, the table, the
requirement verdicts, the security line, the verdict line. Delegated, the
whole return is at most about 400 words, and its last line is
`Reviewed head: <full sha>` - the sha a re-review takes as `--fixes <sha>`.

**The table.** Skip it entirely when nothing survived - no empty table, no
placeholder. Otherwise number the rows and sort by severity, Major then Minor
then Nit. Mark a row from a requirement agent 🔍: it cleared a lower bar. A
house-rule row names its rule - "`engineering`: prefer SUM types over nullable
fields". A row rated from an answer to an intent question says so.

| # | Severity | What | Impact | Fix |
|---|----------|------|--------|-----|
| 1 | Major | `auth.ts:41` - session id compared with `==` | Any user can forge a session by sending an integer | Compare with a constant-time equality on the raw string |
| 2 | Major | 🔍 `retry.ts:88` - backoff resets on every 5xx | A failing endpoint is hot-looped instead of backed off | Carry the attempt count through the retry |
| 3 | Minor | `report.ts:40` - third copy of the date formatter | Three formatters to keep in sync by hand | Call `formatDate` from `shared/date.ts` |

Pre-existing blockers go one line each under the table.

**The requirement verdicts.** Every requirement gets one line: the verdict, the
requirement, and what was actually examined, written from its agent's return.
An agent that returned no verdict is ⚠️, saying so. Every ❌ is also a row,
Major by default.

> ✅ **Met** - no behaviour changes. Checked all 6 changed functions in
> `export/` against their callers and the 14 existing tests.
>
> ❌ **Not met** - the CSV export works for every report type. `summary`
> reports lose their footer; see row 2.
>
> ⚠️ **Unverified** - the cache stays warm across deploys. The deploy hook
> lives in another repo the agent could not read.

**The security line**, one line, from the blockers agent's `checked` line or
your own sweep: `Security: <tier> - <what was checked>`.

> Security: sensitive (DEEP) - sweep clean; 2 workflows checked for pwn
> requests, expression injection, permissions, secrets, pins; cache not
> restored in release job
>
> Security: docs-only - sweep clean on 4 files

**The verdict**, one line, last. It names the rows that drive it and what each
is, and carries the arithmetic - raised versus survived, Met verdicts not
counted. Past three Major rows, name the two worst and count the rest.

> Do not merge - Major row 1 (session id is forgeable) and row 2 (retry
> hot-loops). 9 raised, 3 survived.
>
> Ready to merge 👌 - no Major findings; fix row 3 when convenient. 6 raised,
> 1 survived.
>
> Ready to merge 👌 - nothing serious found. 9 raised, 0 survived.

## The pickers

1. **Which findings survive** - `AskUserQuestion` with `multiSelect`, grouped by
   severity (Major, Minor, Nit, requirements), up to four per question. Skip it
   when nothing survived. More than sixteen means the filtering failed: say so
   and offer the sixteen worst. Every Major is offered, marked recommended.
2. **What to do** - one `AskUserQuestion` with `multiSelect`: **Fix + commit &
   push**, **Fix locally**, **Post to PR**. Then stop until it is answered, and
   act by `references/handover.md`.

Delegated, you cannot ask: after the verdict line, write "Reply with the rows to
keep and an action - fix + commit & push, fix locally, post to PR - or act on
the table yourself.", then the `Reviewed head` line.

## Rules of engagement

- Be specific or be quiet. "This could have security implications" is noise;
  "an unauthenticated POST to `/import` writes to the orders table" is signal.
- One real bug beats ten observations. If the list is long, the bar slipped.
  Never pad a clean diff with gentle suggestions.
- Answer what you were asked: a requirement gets a verdict whether or not
  anything was found there.
- Review only what this diff changes and what it breaks.
- If part of the diff was too large or unfamiliar to judge honestly, say which.
- Drop a finding the moment it is shown wrong; never reach for a replacement.
