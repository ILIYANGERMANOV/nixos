---
name: engineering
description: The engineering principles and coding style to follow for all code work - writing, modifying, refactoring, reviewing or designing code, in any language and at any size, including small changes. Covers domain modeling with ADTs and DDD, SUM types over nullable fields, nominal typing, pattern-matching over early guards, top-down function order, language-idiomatic FP, simplicity, DRY, avoiding premature optimization, strict type-safety, and when to stop and ask the user instead of guessing. Also covers testing across four layers - unit, property-based, differential and end-to-end tests - reproducing a bug at every layer before fixing it, test doubles over mocks, and Given-When-Then structure. Takes precedence over the domain-modeling skill for how to model a domain.
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

## Structuring code

- Code placement: if the code is feature-specific, place it in a
  feature-specific directory. If the code is feature-agnostic and re-usable,
  place it in a shared directory. When unsure whether a given piece of code is
  feature-specific or feature-agnostic, ask. Shared code must be
  feature-agnostic. Feature-specific code must never be shared.

## Testing

Tests exist so we can trust the software without verifying it by hand. Be
pragmatic: the goal is confidence, not a coverage number.

- Coverage: write all four layers below for every feature, limited only by what
  the project supports. Never add a test dependency or a test harness on your
  own - use the tools the repo already has, and when a layer is impossible for
  that reason, say so in one line when reporting the change.
- Unit tests: cover the common happy paths, the common unhappy paths, boundary
  cases (0, MIN, MAX, empty, overflow) and a regression case for every bug that
  was fixed. Exercise the full codepath of the unit under test.
- Property-based tests: the main line of defense, and the spec of the feature -
  they state what must hold over all values of the domain. Before implementing
  logic whose correctness is not obvious (parsers, codecs, calculations, state
  machines), state the properties that must hold and confirm them with the user,
  then implement, then write them. Trivial helpers, wiring and renames skip that
  step.
- Differential tests: when a trusted external implementation exists, test
  against it - `forge cast` as the oracle for an EVM codec. Without one, write a
  model oracle only when a naive implementation is correct by inspection and the
  real one is optimized or clever. If the model would be as intricate as the
  code under test it is not an oracle: write ordinary properties instead.
- Oracle cost: an oracle that is a library runs live in the test. An oracle that
  is a subprocess or a network call is run once over generated inputs and its
  answers committed as a corpus, so the default suite stays fast and hermetic.
  Keep the live run as a separate opt-in target.
- End-to-end tests: exercise as much of the real codepath as possible - golden
  tests for a CLI, request-level tests for a service, driven UI tests for an
  app. Cover the common happy paths and, where practical, the common unhappy
  ones, to prove the product works end to end. No boundary cases; those belong
  to the unit layer.
- When a bug appears in shipped behavior, reproduce it before fixing it: a
  failing unit test, a new property the bug violates, and a failing end-to-end
  test - every layer that can express it, naming the ones that cannot. At least
  one test must be red before the fix, then fix and watch them all go green. The
  property must be a general property of the feature, not the single case
  restated, because a bug is evidence that the spec was incomplete.
- Doubles: prefer the real codepath, and double only what is outside our
  control: the filesystem, HTTP and other network calls, third-party services,
  and nondeterministic edges such as the clock and randomness. Prefer a working
  in-memory fake over a stub, and never double our own domain code. Assert on
  the resulting state and output, not on which calls were made - unless the call
  itself is the behavior under test, such as sending an email.
- Test structure: follow Given-When-Then. Given sets up, When exercises the code
  under test, Then asserts the correct behavior. One When per test, blank lines
  between the phases, and explicit `Given` / `When` / `Then` comments only when
  the phases are not obvious at a glance. Name a test after the behavior it
  pins, not after the function it calls.
- Test placement: the code placement rule above applies to tests. Fixtures and
  doubles that belong to one feature live with that feature; feature-agnostic
  ones belong in a shared test directory so they are reused instead of
  rewritten. Follow the layout the project already uses for test files.
- Reviewing tests: only three of these rules are review findings - a bug fixed
  with no test that was red before the fix, assertions on mocked calls, and a
  double standing in for our own code. A missing layer is never a review
  finding, because whether the project supports that layer is not visible in a
  diff.

## Ask, do not guess

The user chooses the trade-offs and stays in control of them. If a software
design decision is not obvious, stop and ask - never guess. Ask before writing
the code, not after.

## Before you finish

Re-read your diff against these rules and fix what violates them.
