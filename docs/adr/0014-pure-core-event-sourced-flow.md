# A flow is a pure fold over events; effects live in agents and a thin shell

The agent flows in this repository are state machines (ADR 0012). Until now
their state lived in prose and in a hand-written progress file, and nothing
could replay a run. This ADR states the principles a program that carries a
flow must follow, so that it is easy to reason about, testable as a set of
laws, and never dead weight for the agent. ADR 0015 is the first instance.

## Principles

The preference comes from functional programming and category theory: model
the domain as algebraic data types, keep the core pure and total, push every
effect to the edge, and state the laws the core obeys so tests can prove them.
These are the same principles `engineering` applies to all code here; this ADR
applies them to the flows that drive the agents themselves.

Amended by ADR 0018: the principles hold, and the Haskell kernel is now their
instance, its thin shell built on `effectful` effects.

- **Pure core.** The functions that decide what a flow does are pure: same
  input, same output, no clock, no file, no network. They are the only place
  the flow's logic lives.
- **Effects at the edge.** Reading git, appending to a log, printing, and
  everything an agent does with the advice, are effects. They sit in a thin
  shell around the core, or in the agent. The core never performs one.
- **Algebraic data.** Events, states and advice are sum types with named
  constructors. A field is never nullable when a constructor can say what is
  absent. Parsing turns untrusted text into these types once, at the edge, and
  a line that does not parse is an error value, never skipped.
- **Total functions.** Every function on (state, event) is defined on every
  pair. An unknown pair yields an error value; it never throws.
- **Laws as tests.** Each property below is a test, with random inputs where
  the property is universal. A law that cannot be tested is not a law.

## Shape

```text
events.jsonl --parse--> [Event]   pure
[Event]     --fold---> State      pure
State x facts --next-> Advice     pure
Advice      --render-> text       pure
append, read git, print           effect
```

- **Event sourcing.** The only stored thing is an append-only log of events:
  facts in the past tense, each with a dense sequence number, a timestamp and
  the head commit where one exists. Commands are not stored, outcomes are:
  a refused command is stored as its refusal, an outcome too, so a later
  read still sees it.
- **State is a fold.** `state = fold(apply, S0, events)`. `apply` is a left
  fold step and `S0` its unit, so the fold is a monoid action of the event
  sequence on states: an empty log gives `S0`, and folding a concatenation is
  folding one then the other. Replaying the log on any machine gives the same
  state.
- **Advice is a function.** `next(state, facts)` returns advice: what the flow
  suggests the agent do now, with the mechanical payload filled in. `facts` are
  the few values the shell reads from the world, such as the head commit or
  the changed lines.
- **Knobs are events.** A mode such as Quality or Size enters the log as an
  event and reaches the core as a field of the state. A guard that depends on
  a mode is a pure function of the state, never a branch the agent evaluates.

## Laws

A program built on this ADR proves these, each as a test:

| Law | Statement |
|---|---|
| replay | `fold(events)` is deterministic; the same log gives the same state anywhere |
| unit | `fold([]) = S0`; `fold(a ++ b) = fold'(fold(a), b)` |
| append-only | the shell only appends; `seq` is dense from 1 |
| total | `apply` and `next` are defined on every (state, event) |
| advisory | `next` never returns a refusal; only a `Stuck` value names a problem |
| monotone knobs | a knob set once stays; a knob that may change only moves one way |
| fixed targets | an event's target state is a function of the table, except an explicit override |
| prose guard | the rendered table equals the copy the agent reads |

## The agent keeps its judgment

- **Advise, never refuse.** The program says what the flow suggests next and
  why. The agent may do otherwise through an explicit override that names the
  target state and the reason, which is itself an event. ADR 0013: a program
  that limits the agent should not exist.
- **Loops without caps where the agent must decide.** Research, questions and
  blockers are self-loops with no bound. The program records them and shows
  counts against what is typical, as information.
- **Judgment stays in prose.** Which rows to fix, how to slice a task, what to
  ask: the program emits the mechanical payload around those decisions and
  leaves the decision to the agent.

## Considered options

- **State in a hand-written progress file.** Rejected: the current practice.
  Measured, it was missing in 4 of 8 sampled runs and misnamed in 2 of those
  4, and it cannot be replayed.
- **A mutable state file the program rewrites.** Rejected: it loses history,
  so analysis cannot replay a run, and a crash mid-write leaves half a state.
- **A database.** Rejected for a single run: one writer and about fifty events
  need no transactions or indexes; cross-run queries are the analyzer's job
  over many logs.
- **An enforcing machine** that blocks a step out of order. Rejected: it
  limits the agent, and the measured runs show the order holds without it.

## Consequences

- A program that carries a flow (ADR 0015 first) has a pure module with the
  table, `apply`, `next` and `render`, and a shell with `parse`, `append`, the
  git reads and `main`.
- Its tests are the laws above plus the table row by row.
- The self-improve analyzer can replay a flow's log instead of regexing
  transcripts for it (#312).
- Prose that described the record or the mechanics shrinks to one line naming
  the command; prose that holds judgment stays.
