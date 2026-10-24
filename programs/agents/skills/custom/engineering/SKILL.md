---
name: engineering
description: The engineering principles and coding style to follow for all code work - writing, modifying, refactoring, reviewing or designing code, in any language and at any size, including small changes. Covers domain modeling with ADTs and DDD, SUM types over nullable fields, nominal typing, pattern-matching over early guards, top-down function order, minimal function parameters, small and deep modules, language-idiomatic FP, simplicity, DRY and reuse, avoiding premature optimization, strict type-safety, and when to stop and ask the user instead of guessing. Also covers testing across four layers - unit, property-based, differential and end-to-end tests - reproducing a bug at every layer before fixing it, black-box tests through the public interface, realistic fakes over mocks, Given-When-Then structure, and what makes a test meaningless or wrong, detailed in references/tests.md. Takes precedence over the domain-modeling skill for how to model a domain.
---

# Engineering

Apply to all code you write, modify or review, in any language.

## Engineering principles

- Simplicity: complexity is the root of all evil. Prefer simplicity over bloated
  and complicated solutions. Simplicity does not mean ignoring architecture and
  abstraction best practices - the code should be re-usable and scalable.
- DRY: do not repeat yourself. When developing systems, think about how you can
  make them re-usable. Prefer small functions that compose together into
  bigger functions. Abstract the same concept, never merely the same shape; when
  unsure whether it is the same concept, ask.
- Reuse before writing: search the codebase for an existing helper, type or
  module that already expresses the concept, and use or extend it. A second
  copy of the same concept is the moment to extract it - do not wait for a
  third.
- Single source of knowledge: never duplicate knowledge - constants, business
  rules, schemas, validation, lists of names. Derive every consumer from one
  definition, so a change lands in one place and cannot drift.
- Premature optimization: avoid micro-optimization until the user explicitly
  asks for performance. Prefer correctness and maintainability over performance
  and complexity.
- Type-safety: prefer explicit and strict typing. The compiler is your friend
  and it should catch bugs before the program even runs. Define strictly input
  and output types for each function. In dynamic languages use the strongest
  available equivalent - type hints with a checker, schema validation at the
  boundary. Where no type system exists, validate once at the edge and keep the
  core total.

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
  strict domain model. Errors should be caught at compile time rather than
  validated at runtime.
- If you are unsure about the real-world domain model, ask questions and
  interview the user until everything about the domain is crystal-clear. Do this
  before writing code.

## Coding style

- Conditional logic: prefer pattern-matching over early if-return guards. Early
  guards are acceptable only for validation and intentional early termination.
  To run logic based on a SUM type (e.g. `orderType`), pattern-match.
- Programming style: language-idiomatic - write what a senior engineer in that
  language would write. Within that idiom, prefer Haskell-style FP principles:
  immutability, pure functions and side effects pushed to the edges.
- Function order: follow Clean Code top-down ordering. The file reads like a book
  from top to bottom, with the larger public functions at the top and the
  functions they use below them. This applies to code you write - do not reorder
  existing functions unless asked.
- Minimal parameters: a function takes only what it uses - pass the field, not
  the whole record, context or config it lives in. Smaller inputs make the
  dependency visible, the function reusable and the test trivial. The exception
  is a fixed signature: implementing an interface, abstraction or type class
  whose shape is set elsewhere.

## Structuring code

- Code placement: if the code is feature-specific, place it in a
  feature-specific directory. If the code is feature-agnostic and re-usable,
  place it in a shared directory. When unsure whether a given piece of code is
  feature-specific or feature-agnostic, ask. Shared code must be
  feature-agnostic. Feature-specific code must never be shared.
- Small and deep modules: a module hides a lot of behavior behind a small
  interface. The interface is everything a caller must know - signatures,
  invariants, error modes - so depth is a property of the interface, not of
  the line count behind it. Prefer few, deep modules over many shallow
  pass-throughs.
- Deletion test: imagine deleting a module. If its complexity vanishes, it was
  a pass-through - inline it. If the complexity reappears across its callers, it
  earned its keep.
- The interface is the test surface: test a module through its interface, so
  internals can change without rewriting tests - see Testing.
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
  short; a helper moves to the shared ones when a second test needs it.
- Deterministic: no real time, no unseeded randomness, no order dependence, no
  real network.
- Every test must be able to fail: delete or rewrite a test that asserts
  nothing, cannot fail, re-implements the code to compute its expectation,
  duplicates another or pins internals. Never weaken an assertion to make a
  test pass.
- Test placement: the code placement rule above applies to tests. Follow the
  layout the project already uses for test files.
- Reviewing tests: judge tests against the reference and against what the
  change is meant to do. A test that contradicts the intent, a test that can
  never fail and a bug fixed with no test that was red first are fake proofs
  and block the merge. A missing layer is never a review finding, because
  whether the project supports it is not visible in a diff; new public
  behavior with no test at any layer is.

## Ask, do not guess

The user chooses the trade-offs and stays in control of them. If a software
design decision is not obvious, stop and ask - never guess. Ask before writing
the code, not after.

## Before you finish

Re-read your diff against these rules and fix what violates them.
