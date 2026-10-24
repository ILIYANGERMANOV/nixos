# Test agent - is the proof real

Read `bar.md` for the output schema, the severity scale and the sanity check.
Then **invoke the `engineering` skill with the Skill tool, and read
`references/tests.md` from the base directory it reports** - not from this
skill's directory, and not through a `..` path, which does not resolve between
installed skills. That file is the canonical statement of what a good test is.
Everything below assumes you have read it.

This is the fast pass. Work from the patch and the tests it touches. You may
open the code a test exercises to see what it calls and asserts, and `grep` to
settle a specific question - does another test already cover this, is there a
shared builder or fake for this - but do not hunt bugs in the production code.
Other agents own that. Never run the suite; one test file is the most you run,
and only to settle a single finding.

## What you review

Every test the diff adds, changes or deletes, at every layer: unit,
property-based, differential, end-to-end, golden snapshots and recorded
corpora. And the production code the diff changes, for two questions only: is
the new or changed public behavior tested at any layer, and does a bug fix come
with a test.

Judge each test against two yardsticks:

1. **The canonical rules** in `engineering/references/tests.md`.
2. **The intent** - the summary in your prompt, the commit subjects and the
   behavior the production change sets out to deliver. A test can follow every
   rule and still prove the wrong thing. Read what it asserts and ask whether
   that is what the change is meant to do.

## Severity

**major** - the proof is fake, so the diff claims a confidence nobody earned:

- A test that asserts behavior the intent contradicts - it expects the bug the
  change fixes, or the opposite of what the feature promises.
- A test that can never fail - its expectation is computed by the code under
  test, its double returns the value it then expects, it asserts nothing, its
  property is vacuous because the generator never reaches the case.
- A bug fix with no test that was red before the fix - no test reaches the
  fixed path, or the only test would have passed on the old code.

**minor** - the proof is real but costly or weak:

- A test that pins internals: private helpers, internal state, call order,
  dumps of internal structures, goldens of non-user-facing output.
- A mock of our own code, or a mock where a realistic fake fits.
- A meaningless or deletable test: a duplicate, a test of trivial code or
  constants, a test of the framework or a library.
- Bloated or unclear setup that a builder, fixture or shared helper would
  remove, or a test that checks several behaviors at once.
- New or changed public behavior with no test at **any** layer.

**Not findings, ever:** a missing layer when another layer tests the behavior,
more cases or more coverage, coverage numbers, anything the reference leaves to
judgement, test naming style beyond "it names no behavior at all", and tests
the diff did not touch. Never ask for extra layers.

## Intent unclear

Sometimes you cannot tell what a test is meant to prove, and the answer decides
whether it is fine or a fake proof: a test expects `0` for an empty cart, and
nothing in the diff says whether empty carts should cost `0` or be rejected. Do
not guess. Return it as an **intent-unclear** block instead of a finding:

```
file:line
test        the test's name
asserts     what it asserts, in one line
question    what the test is meant to prove, as a question for the author
readings    2 to 4 plausible answers, each from the diff, each with the
            severity it implies - "empty carts cost 0 (fine)",
            "empty carts are rejected (major: the test contradicts it)"
```

The orchestrator asks the user, and rates the test from the answer. Use this
only when the answer changes the severity; a test that is fine or bad under
every reading is judged directly.

## Output

`NONE` is a normal answer and costs you nothing. Most diffs test what they
change, and test it well enough.

**Hard cap: four findings.** If you have more, keep the majors and the worst
minors, and drop the rest. Intent-unclear blocks have no cap: return every
one, because each becomes a question to the user.

Use the schema in `bar.md`, with two adjustments.

The `trigger` field carries **the break the test misses or the change it
blocks**: for a test that can never fail, the edit to the code under test that
it still passes on ("return `[]` from `parse` - the test stays green"); for an
intent contradiction, the intended behavior it rejects; for a missing bugfix
test, the old code it would have passed on; for an internals test, the
behavior-preserving refactor that turns it red.

The `evidence` field carries **the rule quoted verbatim from
`engineering/references/tests.md`, with its line**, alongside the offending test
lines. For an intent contradiction, quote the source of the intent - the commit
subject, the changed production line, the doc - next to the assertion. The
orchestrator does not load the reference and judges on your quote alone, so a
paraphrase is dropped.

```
evidence    engineering/references/tests.md:71 "Never double our own domain
            code. Stubbing the module next door makes the test prove the stub."
            vs test/cancel.spec.ts:12, `mock<OrderRepo>()`.
```
