---
name: refactor
description: Refactors the code a diff touches against the user's engineering and ui-coding rules - DRY first, then derivable state and data modeling, rule violations, deep modules, minimal parameters, needless complexity and tests that fall short of the test rules - without changing behaviour. Plans first, asks before any big item, a schema or stored-data change included, when run by the user (delegated, big items come back as proposals), then applies, checks, commits and pushes. Use after implementing a change and before review, or when asked to clean up or refactor a branch or a PR.
argument-hint: "[Quality: <mode>] [scope notes] [PR number or base ref]"
---

# Refactor

Make the code this diff touches simpler and closer to the house rules, without
changing what it does. Behaviour-preserving only: a refactor that changes
behaviour is a bug hiding in a cleanup commit.

**Delegated** means another agent - an orchestrator such as `engineer` -
invoked this skill, or a `refactorer` agent runs it preloaded, so there is
nobody to ask. Your input is `$ARGUMENTS`, or your prompt when preloaded.

**Quality.** Delegated, your row in the Quality table says whether this runs
and how deep: a skipped diff gets one line saying so, then stop. A quick pass is
step 3's items 1-3, item 3 as one read of the diff, without
`references/tests.md`. Invoked by the user, it runs in full in any mode.

## 1. Load the rules

Invoke the `engineering` skill, and `ui-coding` when the diff touches UI, with
the Skill tool, unless already loaded. They are the yardstick; nothing else
is. When the diff touches tests, also read `references/tests.md` from
`engineering`'s base directory - the detailed test rules. It is not in this skill's
directory, and a `..` path does not resolve between installed skills.

## 2. Read the diff

Your input may carry `Quality: <mode>`, scope notes (anything else that is
not a ref) and a target:

- `Diff: run ctx diff <ref>...` - run it: it wins.
- A PR number or URL - check its branch out first if it is not the current
  one (`gh pr checkout <n>`), then `ctx diff origin/<its baseRefName>`.
- A base ref - `ctx diff <ref>`.
- Neither - `ctx diff origin/main`.

`ctx` diffs the merge-base to the work tree, uncommitted work included. Line 1
is the diff's folder, so no `git diff`: read `index`, then ranges of `diff`. Fail fast if `ctx` fails or says `0 files`. Scope notes narrow or widen
what the plan covers; follow them.

Read lean: the diff hunks, not whole modules. Read past a hunk only for the
range it needs, and find duplicates and existing helpers with `rg -n`, not
by reading files. Your reading budget is about 100k tokens, so applying
still fits: past it, stop
reading, apply what is planned, commit, and report the rest as out of scope.

## 3. Plan

Look at the diff, in this order:

1. **DRY** - a concept implemented twice, inside the diff or against code that
   already exists. Search for the existing helper, type or constant before
   writing a new one, and reuse it.
2. **Derivable state and data modeling** - a stored value computable from
   facts, a copy of state another owner holds, an illegal state the model can
   represent. Removing a stored field or changing a schema changes persisted
   data, so it is a **big** item whatever its size.
3. **Rule violations** - anything in the diff that plainly contradicts a rule
   written in `engineering` or `ui-coding`. Check the diff against all of those
   rules, not only the ones this list names.
4. **Deep modules** - shallow pass-throughs to inline, behaviour that belongs
   behind a smaller interface.
5. **Minimal parameters** - a function handed a whole record, context or config
   when it uses one field.
6. **Needless complexity** - speculative options or generality, defensive code
   for impossible states, single-use layers. Simplify or delete them. Never
   drop a rare edge case's handling here - that changes behaviour; note it for
   the report.
7. **Top-down order** - a file reads like a newspaper: the entry point or
   public function first, then the helpers it calls, each defined below its
   first caller, in the order they are called. Move definitions, never change
   them.
8. **Comments** - delete a comment that restates what the code already says
   (`// increment i`, a docstring repeating the signature), is stale, or is
   commented-out code. Shorten a useful one to the part the code cannot say:
   the why, an invariant, a trap. Keep every comment that explains why.
9. **Good tests** - bring every test the diff adds or changes up to
   `engineering/references/tests.md`, at every layer: unit, property-based,
   differential, end-to-end and goldens. Refactor the tests, not the
   behaviour they prove:
   - **Through the public interface** - rewrite a test that pins internals
     (the reference's *Black box*) to drive the interface and assert what a
     caller observes.
   - **Fakes over mocks** - replace a mock of our own code with the real code,
     and a mock of a boundary with a realistic fake; assert the resulting state
     instead of the calls.
   - **Short setup** - extract repeated setup into builders, fixtures or
     doubles, reuse the shared ones that already exist, and share a helper
     when the reference says it moves.
   - **One behaviour per test** - split a test that checks several, name each
     after the behaviour it pins, and restructure it as Given-When-Then.
   - **Real properties** - fix what the reference's *Property-based* section
     rejects: a re-implemented expectation, a generator that misses the edge
     cases, a property that can pass vacuously.
   - **Delete meaningless tests** - every kind the reference lists under
     *Meaningless tests*.
   - **Never weaken an assertion**, and keep every behaviour previously
     asserted covered by some test: a rewrite that drops a check is a deletion
     in disguise.
   - **Run the tests before and after.** Green before, green after, the same
     behaviours asserted. A test that was red before is not a refactor item;
     note it for the report.

   Tests the diff touches are **small** items. Rewriting tests across the
   suite, adding shared fixtures or doubles outside the diff, or deleting tests
   the diff did not touch are **big** items.

Write the plan as a short numbered list, one line per item: what changes, why
(the rule it serves), and its size - **small** (inside the diff, a few files) or
**big** (touches code outside the diff, restructures across many files, or
changes a public interface or persisted data). The diff is your focus, but you
may read past it to spot a bigger refactor it points at: a better
generalization, DRY across modules, a cleaner design needing a larger rework.
That is a big item. Skip taste: an item no rule backs is not in the plan. An empty plan is a good outcome; say so and stop.

## 4. Ask about the big items

Small items are in scope. Delegated, do not ask: every big item is a
**proposal** in the report, with its scope (files, interfaces) and payoff. Invoked by the user, ask about each **big** item
on its own, the way your instructions say to ask: options "In scope" and
"Out of scope", and the item's cost in the option descriptions. Wait for each
answer.

## 5. Apply

- Apply the approved items in batches of related edits, as few calls as each
  batch allows.
- Keep behaviour identical: same inputs, same outputs, same errors, same side
  effects. Do not fix a bug you find on the way; note it for the report.
- After each batch run the quickest check that covers it. Then sweep the
  branch once for what the review always checks - `rg` the commit subjects
  for TEMP, WIP or debug, and the diff for stray prints, `debugger`,
  commented-out blocks and `TODO: remove` - and fix the hits, so the review
  does not spend a fixer round on them. At the end run the targeted checks
  that cover the whole refactor - lint, format and the tests of the code it
  touched - never the full check; CI has the final say. A failure means the
  refactor changed behaviour or broke something: fix or revert that item.
- Commit with a message naming what was refactored, and push the branch. Never
  force-push, never push `main`.

## 6. Report

Briefly: what was applied, the check that proved it, and the commit. Then the
**proposals** (delegated: each big item, its scope and payoff) and the
**out-of-scope items** - big ones declined and anything noticed outside the
plan, including bugs - as a list for later.
