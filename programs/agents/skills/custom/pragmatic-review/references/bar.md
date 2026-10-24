# The bar

Every reviewing agent reads this. It is the contract for what you may report and
what you owe before you report it.

> **This file is the canonical statement of the bar.** `SKILL.md` restates parts
> of it, because the orchestrator applies the same test in phase 4 and cannot
> read a file the agents were given. The two must move together: change the bar
> here first, then carry the change into `SKILL.md`. Nothing checks that they
> agree, and if they drift the agents filter at one bar while the orchestrator
> judges at another.

## Report only what is not arguable

Report something only if **every senior engineer who saw it would agree it is
wrong** - not "most would find it questionable", but all of them, immediately,
without needing the argument explained to them.

Apply it as a test to each finding before you return it:

> If the author pushed back and said "that's fine", would I be obviously right -
> or would we be having an argument?

An argument means drop it.

Two classes invert this and are reported even when you are unsure: security and
irreversible damage. They belong to the blocker agent and are specified in
`blockers.md`. Unless that file is your brief, the reluctant default above is
yours.

One further override: the `engineering` and `ui-coding` skills are this user's
decided rules, not opinions. If your brief is `scream.md`, a plain violation of
a rule written there - DRY included - is a finding even though it would
otherwise read as taste - the house settled that argument in advance.

## Severity

Every finding you return carries exactly one severity:

- **major** - blocks the merge. Security, irreversible damage, broken behaviour
  (the change fails at what it set out to do, or breaks something that worked),
  obviously broken code, and accidental TEMP, WIP or debug commits or leftover
  debug code.
- **minor** - should be fixed, does not block. A plain violation of a written
  `engineering` or `ui-coding` rule, DRY included, or an approach no competent
  engineer would choose that still works today.
- **nit** - only when it is nearly free to fix and plainly right: a typo in a
  user-facing string, an unused import the diff itself added. Drop every other
  nit.

The diff is mergeable iff no major survives, so do not inflate a finding to
major to get it noticed, and do not soften a broken path to minor.

## Requirements get the depth

The user may give **requirements**: statements that must hold, such as "no
behaviour changes" or "the export still works". Every one goes to a dedicated
**requirement agent**; the three standard agents never carry one.

If you are a **requirement agent**, your requirements are your whole job. Verify
each one **in depth**: read the callers, follow the data, probe the behaviour,
run the cheap check that settles it, go outside the diff if it points there. It
is the one place in this review where depth is wanted, and inside your
requirements' scope the bar is lower: a real answer the user might disagree with
is still worth returning. The other briefs are background for the angle your
requirements touch, not work you owe.

If you are a **standard agent**, the requirements are not yours. Do not spend
effort on them; a requirement agent covers that ground.

## Outside the requirements, a fast sanity check

Everything not covered by a requirement gets a fast pass: read the diff, flag what is
obviously wrong, do not probe deeply. The blocker agent's sweep and its
verification are the exception - `blockers.md` says how careful to be.

Every agent checks these, because they cost one read of the patch:

- **Accidental TEMP, WIP or debug commits** - run the commit-list command in your
  prompt and look at the subjects - and leftover debug code in added lines:
  stray prints and logs, `debugger`, commented-out blocks, hard-coded test
  values, `TODO: remove`.
- **Obviously broken things** - a syntax error, a file the diff references but
  does not add, a call to a symbol that does not exist, a path that points
  nowhere. A grep settles each of these; never a build.

Each is a major.

## What is never a finding

Regardless of how confident you are: style, naming, formatting, comment
wording, import order, accessibility, micro-optimisations, test-coverage wishes,
hypothetical future requirements, super edge cases no real input reaches,
refactors of code the diff did not touch, and every nit that is not nearly free
to fix.

A rule written in `engineering` or `ui-coding` is not style, and this list does
not cover it - see `scream.md`, which owns those.

## Scope

Review what this diff changes and what it breaks. Do not review code the diff
did not touch - unless you are a requirement agent and your requirement sends
you there, and then what you find there is marked `pre-existing`, because it is
answered but does not block the merge.

## Refute yourself before you return

You have the code paths loaded and the orchestrator does not. Killing a wrong
finding is cheap here and expensive anywhere else, so it is your job.

For each candidate finding:

1. Read the real code path, not the diff hunk. Is the input already validated
   upstream? Is the branch reachable? Is the case already handled elsewhere?
2. Actively try to refute it. Assume it is wrong until you can walk from a
   concrete input to a concrete wrong outcome.
3. Run a check only if it would settle this specific finding and is cheap and
   narrow - a grep, one test file, a single-file type check. Never a full build,
   test suite or lint sweep, and never an exploratory run. Never write files,
   never install anything, never run anything with side effects.

A finding you refuted is dropped silently and never mentioned. A finding that
survived is reported with the attempt attached.

## What you return

`NONE` when nothing survived. That is a good answer and it costs you nothing -
most healthy diffs contain no finding at all, and an invented one wastes more of
the author's time than silence ever does.

Otherwise one block per finding, and nothing else - no preamble, no summary of
what you read (unless you are a requirement agent, which changes this; see
below):

```
file:line
severity    major | minor | nit
claim       one sentence, what is wrong
trigger     concrete inputs or state -> the wrong outcome
confidence  certain | likely | speculative
refuted?    what you tried in order to kill it, and why it survived
evidence    the one or two lines of real code the claim rests on
```

**No trigger means no finding.** If you cannot name the conditions under which
the problem actually happens, you do not report it.

**No refutation attempt means no finding.** The orchestrator judges on that
field without reopening the file, so "I did not check" reads as a hand-wave and
gets dropped.

**Keep the whole return under 300 words.** A requirement agent may use 500. The
orchestrator reads every return in one context, so words spent on prose are
words taken from the findings.

### A requirement agent owes a verdict on each requirement

The rule above - findings and nothing else - is for the standard agents. A
requirement is a direct demand from the user, answered even when the answer is
"it holds". So a requirement agent **always** returns one verdict per
requirement, above any findings, including when its findings are `NONE`:

```
requirement  the requirement, as worded in your prompt
verdict      met | not met | unverified
examined     the files, paths and cases you actually checked
```

- **not met** - also return the finding that shows it, as a `major` block below.
- **unverified** - you could not settle it. Say why, and name what you would
  need. A requirement too vague to check, or one you could only partly cover,
  is unverified - never a guess at a plausible interpretation, and never an
  implied full check.

The `examined` line says **what you actually examined** - which files, which
paths, which cases - so the user can tell a real check from a shrug. It is the
one place a summary of what you read is required rather than forbidden. The orchestrator
cannot write this line for you: it is not permitted to reopen the code, so what
you leave out is simply lost, and the user is told nothing was looked at.

## Working rules

- Your prompt carries the exact command that produces the diff, with the base
  already pinned. Run it once, and use that. Do not widen the range, and do not
  work out a base of your own.
- Your prompt names the files most relevant to your angle. Start there. You may
  go wider when your angle demands it - the routing is a starting point, not a
  fence.
- Be specific or be quiet. "This could have security implications" is noise; "an
  unauthenticated POST to `/import` writes to the orders table" is signal.
- If part of the diff is too large or too unfamiliar to judge honestly, say
  which part you could not assess rather than implying you covered it.
