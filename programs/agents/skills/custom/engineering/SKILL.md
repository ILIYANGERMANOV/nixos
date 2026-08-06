---
name: engineering
description: The engineering principles and coding style to follow for all code work - writing, modifying, refactoring, reviewing or designing code, in any language and at any size, including small changes. Covers domain modeling with ADTs and DDD, SUM types over nullable fields, nominal typing, pattern-matching over early guards, top-down function order, language-idiomatic FP, simplicity, DRY, avoiding premature optimization, strict type-safety, and when to stop and ask the user instead of guessing. Takes precedence over the domain-modeling skill for how to model a domain.
---

# Engineering

Apply to all code you write, modify or review, in any language.

## Domain modeling

This skill governs how to model a domain. Use `/domain-modeling` only when the
resulting terms should be recorded as a glossary or an ADR.

- Use ADTs and follow DDD (Domain Driven Design). The domain model must match
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
  language would write. Within that idiom, prefer FP Haskell style principles:
  immutability, pure functions and side effects pushed to the edges.
- Function order: follow Clean Code top-down ordering. The file reads like a book
  from top to bottom, with the bigger public function at the top and the
  functions it uses below it. This applies to code you write - do not reorder
  existing functions unless asked.

## Engineering principles

- Simplicity: complexity is the root of all evil. Prefer simplicity over bloated
  and complicated solutions. Simplicity does not mean ignoring architecture and
  abstraction best practices - the code should be re-usable and scalable.
- DRY: do not repeat yourself. When developing systems, think about how you can
  make them re-usable. Prefer small functions that composed together build
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

## Ask, do not guess

The user chooses the trade-offs and stays in control of them. If a software
design decision is not obvious, stop and ask - never guess. Ask before writing
the code, not after.

## Before you finish

Re-read your diff against these rules and fix what violates them.
