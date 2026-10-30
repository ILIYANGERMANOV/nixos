---
name: engineering
description: The engineering principles and coding style to follow for all code work - writing, modifying, refactoring, reviewing or designing code, in any language and at any size, including small changes. Covers ADT and DDD domain modeling, minimal state, idempotence, data evolution, parsing into narrower types, errors as values, SUM types over nullable fields, nominal typing, pattern-matching, top-down function order, minimal parameters, small and deep modules, comments, a pure core with a thin effect shell, task lifetimes, simplicity and edge-case ROI, DRY and reuse, strict type-safety, bounded file reads, and when to ask the user instead of guessing. Also covers testing across four layers - unit, property-based, differential and end-to-end tests - reproducing a bug at every layer before fixing it, black-box tests through the public interface, realistic fakes over mocks, Given-When-Then structure, and what makes a test meaningless or wrong. Takes precedence over the domain-modeling skill for how to model a domain.
---

# Engineering

Apply to all code you write, modify or review, in any language.

## Simplicity

The most important principle. Complexity is the main cost of software; avoid
it at any cost. Simple is not naive: it is the fewest moving parts that still
meet the objective correctly and sanely.

- Solve the stated problem. Keep sound architecture and reuse what exists, but
  add no flags, options, hooks, layers or generality for needs nobody has named
  (see Seams).
- Edge-case ROI: make the common cases correct and reliable. When a rare edge
  case needs a complex, fragile or flaky fix, skip it and say so in the code,
  the PR or the hand-back - never drop one silently. Still fix it when the fix
  is cheap, or when a miss corrupts data or opens a security hole.
- Not naive: no hacks, no swallowed errors, nothing wrong on the main path.
- Trust your invariants: parse at the boundary into a narrower type (`Email`, a
  non-empty list) and take that type inside; validation returns a new type,
  never a bool. Parse all input before the first side effect. Add no defensive
  checks, retries or fallbacks for states the types or callers rule out.
- Boring code: the standard library over a new dependency, a direct
  expression over a clever one.
- Grow from a working simple version; a complex system built from scratch
  rarely works (Gall's law).
- Before finishing, ask what you can delete and still meet the goal: freely
  what you wrote, existing code only once you know why it exists and who relies
  on it (`git log -L`, `rg`, its tests). No reason found: keep it or ask.

## Engineering principles

- DRY: do not repeat yourself. Prefer small functions that compose together
  into bigger functions. Abstract the same concept, never merely the same
  shape; when unsure whether it is the same concept, ask. Extract only what
  stands alone: its name and signature explain it, without its body or caller.
- Reuse before writing: search the codebase for an existing helper, type or
  module that already expresses the concept, and use or extend it. A second
  copy of the same concept is the moment to extract it - do not wait for a
  third.
- Single source of knowledge: never duplicate knowledge - constants, business
  rules, schemas, validation, lists of names. Derive every consumer from one
  definition, so a change lands in one place and cannot drift. Mutable runtime
  state likewise has one owner: only it writes, others read an immutable view.
- Minimal state: store the facts with the most information and derive the rest,
  in the database, UI and memory alike: `createdAt`, never `isExpired`. A state
  computable from facts is a SUM a function returns, not a field. Should old
  records change with the rule? Yes derive, no store: a value that must survive
  a rule change (invoice total) is a fact. Exception: a named performance need,
  such as an indexed `expiresAt`. A derived store (cache, index, denormalized
  copy) is disposable, rebuildable and takes no own writes.
- Idempotence: a webhook, consumer, cron or retry can run twice. Key the effect
  on a stable id with a unique constraint or upsert, not check-then-write.
- Data outlives code: old rows meet new code, and mid-deploy old code meets new
  data. Change a stored or wire format in steps: add, migrate, remove.
- Task lifetimes: every spawned task has an owner that awaits it, gets its
  failure and cancels it. A catch-all handler rethrows cancellation.
- Premature optimization: no micro-optimization until the user explicitly asks
  for performance. Prefer correctness and maintainability over performance.
- Type-safety: prefer explicit and strict typing, so the compiler catches bugs
  before the program runs. Define strictly input and output types for each
  function. In dynamic languages use the strongest available equivalent - type
  hints with a checker, schema validation at the boundary. Where no type system
  exists, validate once at the edge and keep the core total.

## Domain modeling

This skill governs how to model a domain.

- Use ADTs and follow DDD (Domain-Driven Design). The domain model must match
  the business reality exactly and have a 1:1 relationship with the real world.
- Prefer SUM (union) types over nullable (optional) fields. Nullable is
  acceptable only when the field is optional by domain - an item has a mandatory
  title and an optional description. If absence encodes a state (pending,
  cancelled, unverified), model the states as a SUM type.
- Use nominal typing: prefer an `OrderId` type over a `String`.
- Impossible cases in the domain must be unrepresentable by your type-safe and
  strict domain model. Count to check: `{status: 3 cases, data?, error?}` admits
  12 values where 3 states exist, so make it a SUM. Storage too: constraints for
  uniqueness, references and required fields, atomic updates over
  read-modify-write.
- Typed transitions: take the exact state and return the next,
  `ship(PaidOrder): ShippedOrder`, not `ship(Order)` with a status check.
- If you are unsure about the real-world domain model, ask questions and
  interview the user until everything about the domain is crystal-clear. Do this
  before writing code.

## Coding style

- Conditional logic: prefer pattern-matching over early if-return guards. Early
  guards are acceptable only for validation and intentional early termination.
  To run logic based on a SUM type (e.g. `orderType`), pattern-match, and
  exhaustively on your own SUM types: no `default` or `_`, except an arm whose
  only job is proving exhaustiveness (`assertNever`), so a new case breaks the
  build at every site. Never check then force (`x!!`, `has` then `get`, a
  cast): match once and use the bound value.
- Errors: a failure the caller can act on (not found, rejected) is a SUM value
  in the return type; a bug or outage throws. A goal that already holds
  (deleting what is absent) succeeds. Handle a failure once, where it can be
  decided: no log-and-rethrow, no catch returning null or a default.
- Comments: state what the code cannot - why, invariants, units, a trap. Never
  restate the line below or narrate the change; that belongs in the commit.
- Programming style: language-idiomatic - write what a senior engineer in that
  language would write. Within that idiom, prefer Haskell-style FP principles:
  immutability, pure functions and a thin effect shell: read, decide in a pure
  function over plain values, then write, with the read inside the same
  transaction or the write conditional on what was read, so a concurrent stock
  decrement cannot lose an update. Pass time, ids and randomness in. If testing
  a decision needs a fake, the decision is in the shell.
- Function order: Clean Code top-down. A file reads like a book, the larger
  public functions at the top and the functions they use below them. This
  applies to code you write - do not reorder existing functions unless asked.
- Minimal parameters: a function takes only what it uses - the field, not the
  whole record, context or config it lives in - so the dependency is visible,
  the function reusable and the test trivial. The exception is a fixed
  signature: an interface, abstraction or type class whose shape is set
  elsewhere.

## Structuring code

- Code placement: feature-specific code goes in a feature-specific directory
  and is never shared; feature-agnostic, re-usable code goes in a shared
  directory, which holds nothing else. When unsure which it is, ask.
- Small and deep modules: a module hides a lot of behavior behind a small
  interface. The interface is everything a caller must know - signatures,
  invariants, error modes - so depth is a property of the interface, not of
  the line count behind it. Prefer few, deep modules over many shallow
  pass-throughs. Split by the knowledge hidden, never by execution order: if one
  format or rule change touches two modules, merge them or move the knowledge.
- Deletion test: imagine deleting a module. If its complexity vanishes, it was
  a pass-through - inline it. If the complexity reappears across its callers, it
  earned its keep.
- Seams: one adapter behind an abstraction is a hypothetical seam, two is a real
  one. Do not introduce an abstraction for a single implementation unless a
  second is concretely planned.

## Testing

Tests exist so we can trust the software without verifying it by hand. Be
pragmatic: the goal is confidence, not a coverage number. Read
`${CLAUDE_SKILL_DIR}/references/tests.md` before writing, changing or reviewing
a test - it is the detailed statement of every rule below, with examples.

- Black box: test a unit through its public interface and assert what a caller
  can observe - return values, errors, resulting state, output. Never test
  private helpers, internal state, call order or dumps of internal structures.
  A test fails only when observable behavior breaks, and survives every
  refactor that preserves it.
- Layers: write all four for every feature, limited only by what the project
  supports - unit, property-based, differential and end-to-end. Never add a
  test dependency or a test harness on your own; when a layer is impossible
  for that reason, say so in one line when reporting the change.
- Properties first: they are the main line of defense and the spec of the
  feature. Before implementing logic whose correctness is not obvious
  (parsers, codecs, calculations, state machines), state the properties that
  must hold and confirm them with the user, then implement, then write them.
- Bugs are red first: reproduce a bug in shipped behavior at every layer that
  can express it before fixing it. At least one test must be red before the
  fix.
- Fakes over mocks: double only what is outside our control - the filesystem,
  the network, third-party services, the clock, randomness - with a realistic
  in-memory fake that mirrors the real thing. Never double our own domain
  code. Assert on the resulting state, not on which calls were made, unless
  the call itself is the behavior, such as sending an email.
- Simple and concise: Given-When-Then, one behavior per test, named after the
  behavior it pins. Builders, fixtures and shared test utilities keep setup
  short; a helper moves to the shared ones when a second test file needs it.
- Deterministic: no real time, no unseeded randomness, no order dependence, no
  real network.
- Every test must be able to fail: delete or rewrite a test that asserts
  nothing, cannot fail, re-implements the code to compute its expectation,
  duplicates another or pins internals. Break the code a new test covers once,
  see it go red, restore. Never weaken an assertion to make a test pass. A test
  you cannot pass honestly is reported, never special-cased.
- Test placement: the code placement rule above applies to tests. Follow the
  layout the project already uses for test files.
- Reviewing tests: judge tests against the reference and against what the
  change is meant to do. How severe each problem is belongs to the
  `pragmatic-review` skill.

## Ask, do not guess

The user chooses the trade-offs and stays in control of them. If a software
design decision is not obvious, stop and ask - never guess. Ask before writing
the code, not after. A subagent, which cannot ask, hands the decision back to
its caller instead.

## Reading code

Every line you read is carried, and paid for, on every later call.

- Find, then read: `rg -n`, then only that range with `sed -n`. Never `cat`
  several large files or `git show <ref>:<file>` in full. Small files together
  are fine up to 8KB combined.
- Diffs: `git diff --stat` first, then file by file. When rebasing or comparing
  refs, read `git diff <ref> -- <file>`, never both versions.
- Never read back output that was spilled to a file: `rg` it, or rerun the
  command narrower.

## Before you finish

Passing tests is not done. Re-read your diff against the request and these
rules and fix what violates them: a behaviour change beyond the request gets a
reason or goes. Every claim in a hand-back or PR matches the diff or a command
you ran.
