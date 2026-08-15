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
a rule written there is a finding even though it would otherwise read as taste -
the house settled that argument in advance.

## What is never a finding

Regardless of how confident you are: nits, style, naming, formatting, comment
wording, import order, accessibility, micro-optimisations, test-coverage wishes,
hypothetical future requirements, and refactors of code the diff did not touch.

A rule written in `engineering` or `ui-coding` is not style, and this list does
not cover it - see `scream.md`, which owns those.

## Scope

Review what this diff changes and what it breaks. Do not review code the diff
did not touch - unless a tip in your brief sends you there, and then what you
find there is marked `pre-existing`, because it is answered but does not block
the merge.

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
what you read (unless your brief carries a tip, which changes this; see below):

```
file:line
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

### If your brief carries a tip, you owe a verdict as well

The rule above - findings and nothing else - is what an agent returns when its
brief is only the standard one. A tip is extra ground handed to you on top of
that brief, and it is a direct question from the user, answered even when the
answer is "nothing wrong here". So if your brief carries one you **always**
return a short verdict on it, above any findings, including when your findings
are `NONE`.

The tip never displaces your standard brief - you finish that either way, and
your scope simply widens to wherever the tip points, including code this diff did
not touch, where what you find is marked `pre-existing`. If you run out of room
to do both properly, say which part you could not cover. That is a usable answer;
implying you covered both is not.

The verdict says **what you actually examined** - which files, which paths, which
cases - so the user can tell a real check from a shrug. It is the one place a
summary of what you read is required rather than forbidden. The orchestrator
cannot write this line for you: it is not permitted to reopen the code, so what
you leave out is simply lost, and the user is told nothing was looked at.

If the tip was too vague to check, say so and name what you would need, rather
than inventing a plausible interpretation of it.

## Working rules

- The patch has already been produced for you at the path in your prompt. Read
  it there. Do not run `git diff`, `gh pr diff` or any other command to
  re-derive it.
- Your prompt names the files most relevant to your angle. Start there. You may
  go wider when your angle demands it - the routing is a starting point, not a
  fence.
- Be specific or be quiet. "This could have security implications" is noise; "an
  unauthenticated POST to `/import` writes to the orders table" is signal.
- If part of the diff is too large or too unfamiliar to judge honestly, say
  which part you could not assess rather than implying you covered it.
