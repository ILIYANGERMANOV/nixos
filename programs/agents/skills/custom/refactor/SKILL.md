---
name: refactor
description: Refactors the code a diff touches against the user's engineering and ui-coding rules - DRY first, then rule violations, deep modules and minimal parameters - without changing behaviour. Plans first, asks before any big item, then applies, checks, commits and pushes. Use after implementing a change and before review, or when asked to clean up or refactor a branch or a PR.
argument-hint: "[scope notes] [PR number or base ref]"
---

# Refactor

Make the code this diff touches simpler and closer to the house rules, without
changing what it does. Behaviour-preserving only: a refactor that changes
behaviour is a bug hiding in a cleanup commit.

When another agent invoked this skill - an orchestrator such as `engineer` - that
agent answers the questions below in place of the user.

## 1. Load the rules

Invoke the `engineering` skill, and `ui-coding` when the diff touches UI, with
the Skill tool. They are the yardstick; nothing else is.

## 2. Read the diff

`$ARGUMENTS` may carry scope notes (anything that is not a ref) and a target:

- A PR number or URL - `gh pr diff <n>`. Check the PR's branch out first if it
  is not the current one (`gh pr checkout <n>`).
- A base ref - `git diff $(git merge-base HEAD <ref>)`.
- Neither - the current branch against
  `git merge-base HEAD origin/main`, including uncommitted work.

Fail fast if the ref does not resolve or the diff is empty. Scope notes narrow
or widen what the plan covers; follow them.

## 3. Plan

Look at the diff, in this order:

1. **DRY** - a concept implemented twice, inside the diff or against code that
   already exists. Search for the existing helper, type or constant before
   writing a new one, and reuse it.
2. **Rule violations** - anything in the diff that plainly contradicts a rule
   written in `engineering` or `ui-coding`.
3. **Deep modules** - shallow pass-throughs to inline, behaviour that belongs
   behind a smaller interface.
4. **Minimal parameters** - a function handed a whole record, context or config
   when it uses one field.
5. **Top-down order** - a file reads like a newspaper: the entry point or
   public function first, then the helpers it calls, each defined below its
   first caller, in the order they are called. Move definitions, never change
   them.
6. **Comments** - delete a comment that restates what the code already says
   (`// increment i`, a docstring repeating the signature), is stale, or is
   commented-out code. Shorten a useful one to the part the code cannot say:
   the why, an invariant, a trap. Keep every comment that explains why.
7. **Meaningful tests** - a test the diff adds or changes must fail if the
   behaviour it names broke. Flag tests that assert nothing, assert only that a
   mock was called, re-implement the code under test to compute the expected
   value, or duplicate another test. Fix by asserting the observable outcome,
   or delete the test. Never weaken an assertion to make it pass.

Write the plan as a short numbered list, one line per item: what changes, why
(the rule it serves), and its size - **small** (inside the diff, a few files) or
**big** (touches code outside the diff, restructures across many files, or
changes a public interface). Skip taste: an item no rule backs is not in the
plan. An empty plan is a good outcome; say so and stop.

## 4. Ask about the big items

Small items are in scope. Ask about each **big** item on its own with
`AskUserQuestion` - one question per call, options "In scope" and "Out of
scope", your recommendation first with `(Recommended)` in its label, and the
item's cost in the option descriptions. Wait for each answer.

## 5. Apply

- Apply the approved items, one at a time.
- Keep behaviour identical: same inputs, same outputs, same errors, same side
  effects. Do not fix a bug you find on the way; note it for the report.
- Run the repo's own checks and tests for what you changed - its `Justfile`,
  its flake checks, its test command. A failure means the refactor changed
  behaviour or broke something: fix or revert that item.
- Commit with a message naming what was refactored, and push the branch. Never
  force-push, never push `main`.

## 6. Report

Briefly: what was applied, the check that proved it, and the commit. Then the
**out-of-scope items** - the big ones declined and anything noticed outside the
plan, including bugs - as a list for later.
