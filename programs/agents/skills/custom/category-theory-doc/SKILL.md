---
name: category-theory-doc
description: Write a Category Theory model of a design, when asked for one.
---

# Category Theory model of a design

Write a model that is small, honest and testable: a few plain structures, each
claim checkable, each property a test.

Read `${CLAUDE_SKILL_DIR}/references/example.md` for the shape of each
section: one complete model of a made-up app. Copy its shapes, never its
domain.

## Ground rules

- **Use the least structure that works.** Most designs need only ordered sets
  (`⊆`, `≤`), a state machine and a log. Do not reach for categories,
  adjunctions or monads to sound rigorous.
- **Name a map a functor only if it is one.** If it breaks the order (a step
  that moves something down), call it a plain function and say why.
- **Every claim becomes a test.** A property you cannot test is an
  assumption: label it one.
- **Derive, do not store.** A value that is a function of state is defined as
  that function, never as a field.
- **Separate verified from assumed.** Each property carries one of the
  statuses in section 6.
- **Plain words first, symbols second.** Each formula sits next to a sentence
  or a table row that says it in English. Short sentences, tables, small
  diagrams.
- **Facts come from the code.** Read the design and its code; never state a
  fact from memory.

## Section order

Each section builds only on the ones above it. A section that does not
apply keeps its heading and one line saying why it is empty (for example,
no natural rank); never invent structure to fill it.

```text
0. Model at a glance   -> what structures exist, how they connect
1. Env                 -> what the model is parameterized by
2. Objects + lattice   -> the base type and its sets, ordered by ⊆
3. Order               -> a ranked chain and a monotone map into the lattice
4. Lifecycle + log     -> state machine, events as a free monoid, state as fold
5. Principals          -> who can turn what into what (labelled graph)
6. Properties          -> numbered claims, each a test, each with a status
7. Notes               -> the verified facts behind the statuses
8. Open in the model   -> questions the model raises but does not settle
```

### 0. Model at a glance

- One sentence naming the kinds of structure, then a table: structure,
  objects, kind.
- One small mermaid diagram; each arrow is a named function.
- One line on which arrows are not functors, and why.

### 1. Env

- List what the whole model is defined per, with each instance's values
  written out.
- If two instances must never mix, label it an assumption checked by a test,
  and say what the model cannot tell apart on its own.

### 2. Objects + lattice

- Define the base object by its attributes and their types; use `⊔ {none}`
  for "may be absent". Say which edge cases are still objects.
- The lattice is `(𝒫(Objects), ⊆)` with `∩`, `∪` and complement. Name sets in
  a table, each defined from earlier ones.
- Derive the facts you need, such as a disjointness, in one or two lines.

### 3. Order

- A ranked chain and a map into the lattice, written as an intersection with
  a set `G(l)` that grows with the rank.
- State the consequence (`G` grows, so the map is monotone) and which
  inclusions are strict.

### 4. Lifecycle + log

- A table of stored fields, then derived values as small equations. Draw
  the state diagram with the actor on each edge, and list preconditions.
- Events form a free monoid, each with an actor and an id. State is the fold
  of transitions over the log; views are folds over the same log.
- Say what freeness does not give: views agree only if they read the same
  committed log and apply each event once, so with at-least-once delivery
  each projection is idempotent per event id.

### 5. Principals

- A table of principals, then the graph, with each edge labelled by the actor
  that can take it.
- Say which actions are not edges, and define `allowed(principal)` from the
  order map and state.
- Say what keys such as rate limits are a function of, and what they must not
  contain.

### 6. Properties

- A table: `# | Property | Statement | Status`. Each row is a test.
- Property is a short English name; Statement is the claim in the model's
  terms, one or two lines.
- Status is `Holds`, `Holds (how verified)`, `Holds if <condition>`,
  `Needs <change>` or `Assumed`. `Holds if X` means it holds today and
  future code must keep `X`.
- Every non-trivial status names its backing: a Note, a test, or the
  construction (`Holds (derived in section 2)`).

### 7. Notes

- Short facts that back a status, each tagged `(verified)` and tied to its
  property.

### 8. Open in the model

- Bullets for questions the model surfaces but the design has not decided.

## Checklist

- [ ] At most five structures, each named by its real kind
- [ ] No functor claimed without checking it preserves the order
- [ ] Every set defined from earlier ones, in a table
- [ ] Derived values are functions, not fields
- [ ] Log, fold and the idempotence caveat stated if there is an event log
- [ ] Every property has a statement and a status, and is a test
- [ ] Assumptions labelled as assumptions
- [ ] Every formula has a plain-English twin
- [ ] Mermaid diagrams small: one per section at most
