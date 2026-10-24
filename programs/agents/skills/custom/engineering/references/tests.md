# What a good test is

The canonical statement of how to write, refactor and judge tests. `SKILL.md`
carries the principles; this file carries the detail. The `refactor` and
`pragmatic-review` skills load it too, so a rule written here is the rule all
three apply.

A test is a proof that a behavior holds. It is worth exactly as much as the
confidence it buys: a test that cannot fail, or fails for the wrong reason, is
worse than no test, because it buys confidence nobody earned.

## Black box

- **Test through the public interface.** Call what a caller calls - the
  exported function, the module's API, the endpoint, the CLI - and nothing
  else. Never reach for a private helper, an internal module, a private
  constructor or a field the interface does not expose. If a behavior cannot
  be reached from the interface, it is not a behavior: it is an implementation
  detail, or dead code.
- **Assert what a caller can observe.** Return values, errors, the resulting
  state read back through the interface, output written to the outside world.
  Never assert call order, the number of internal calls, internal state, which
  private function ran, or a derived `Show` / `toString` / snapshot dump of an
  internal structure.
- **A test fails only when observable behavior breaks.** It survives every
  refactor that preserves behavior: renaming a helper, inlining a module,
  changing a data structure, reordering internal steps. A test that goes red on
  a pure refactor is pinning the implementation, and it taxes every future
  change while proving nothing about the product.

```ts
// Bad: pins the internals. Breaks when the cache becomes an LRU.
expect(service["cache"].size).toBe(1);
expect(repo.find).toHaveBeenCalledTimes(1);

// Good: pins the behavior a caller sees.
expect(await service.price(sku)).toEqual(Money.eur(12));
```

## Simple and concise

- **The test reads as the behavior.** A reader sees the setup, the action and
  the expectation without scrolling. Setup that drowns the point is a smell in
  the test code, not a necessity.
- **Build inputs with builders and fixtures.** A builder with sensible
  defaults (`anOrder().withItems(2).build()`) states only what this test cares
  about; the rest is noise the builder hides. A fixture holds a realistic
  sample - a project tree, a config file, a recorded response.
- **Share what a second test needs.** A helper stays private to its test file
  until a second file needs it; then it moves to the project's shared test
  utilities, never copied. The same DRY rule as production code.
- **No logic in the test.** No loops computing expectations, no branches, no
  try/catch that swallows the failure. A test with logic needs its own test.

## Doubles: fakes over mocks

- **Prefer the real code path.** Double only what is outside our control: the
  filesystem, the network, a database, third-party services, the clock,
  randomness.
- **Prefer a realistic fake.** A working in-memory implementation of the same
  interface - an in-memory filesystem, database, clock or HTTP server, a fake
  language for a compiler driver - behaves like the real thing, so the test
  exercises real logic against it. Make the fake mirror the real thing as
  closely as you can: the same errors, the same edge cases, the same ordering
  guarantees. A fake that is more forgiving than production hides bugs.
- **Avoid mocks.** A mock scripted with expectations (`when(x).thenReturn(y)`,
  `verify(z).called()`) asserts on the conversation, not the outcome, and pins
  the implementation. Use one only when the call itself is the behavior - an
  email sent, a payment charged, a metric emitted - and then assert that call
  and nothing else.
- **Never double our own domain code.** Stubbing the module next door makes the
  test prove the stub. Use the real one.
- **Assert on the resulting state and output**, not on which calls were made.

```ts
// Bad: a mock of our own repository, asserting the call.
const repo = mock<OrderRepo>();
await cancel(orderId, repo);
verify(repo.save).calledWith(match({ status: "cancelled" }));

// Good: a fake of the boundary, asserting the state.
const db = InMemoryDb.with(anOrder({ id: orderId }));
await cancel(orderId, db);
expect(await db.orders.get(orderId)).toMatchObject({ status: "cancelled" });
```

## Structure

- **Given-When-Then.** Given sets up, When exercises the code under test once,
  Then asserts. Blank lines between the phases; explicit `Given` / `When` /
  `Then` comments only when the phases are not obvious at a glance.
- **One behavior per test.** One When, and Then asserts that one behavior -
  several assertions are fine when together they describe it. A test that
  checks parsing, then validation, then rendering is three tests: when it fails
  its name does not say which behavior broke.
- **Name it after the behavior it pins**, not the function it calls:
  `rejects an expired token`, not `test_validate_3`. The list of test names
  reads as the specification.

## Deterministic

A test gives the same answer every run, on every machine, in any order.

- **No real time.** Inject the clock; never `sleep`, never compare against
  `now()`.
- **No unseeded randomness.** Property tests print their seed and replay it.
- **No order dependence.** Each test builds its own state; nothing leaks
  between tests through globals, shared files or a shared database.
- **No real network** and no machine-specific paths. A flaky test is a broken
  test: fix the nondeterminism, never retry it into green.

## The layers

Write every layer the project supports for every feature. Never add a test
dependency or harness on your own; when a layer is impossible with what the
repo has, say so in one line when reporting the change.

### Unit

Cover the common happy paths, the common unhappy paths, boundary cases (0, MIN,
MAX, empty, overflow) and a regression case for every fixed bug. Exercise the
full code path of the unit through its interface.

### Property-based

The main line of defense, and the spec of the feature: properties state what
must hold over every value of the domain.

- **A real property, not a re-implementation.** State what holds - a
  round-trip (`decode . encode == id`), an invariant (sorted output is a
  permutation of the input and ordered), an algebraic law, an oracle relation.
  A property that computes the expected value with the same algorithm as the
  code proves only that the code equals itself.
- **Generators cover the edge cases.** Empty, singleton, maximal, unicode,
  duplicates, negative, boundary values. A generator that never produces the
  hard inputs makes the property vacuous.
- **Guard against vacuous passes.** Use `cover` / `classify` / labels (or the
  framework's equivalent) to require that the interesting cases are actually
  generated, and avoid preconditions that discard most inputs.
- Before implementing logic whose correctness is not obvious - parsers,
  codecs, calculations, state machines - state the properties and confirm them
  with the user, then implement, then write them. Trivial helpers, wiring and
  renames skip that step.

```haskell
-- Bad: restates the implementation.
prop_total xs = total xs === sum (map price xs)

-- Good: a law the implementation must obey.
prop_totalSplits xs ys = total (xs <> ys) === total xs + total ys
```

### Differential

When a trusted external implementation exists, test against it - `forge cast`
as the oracle for an EVM codec, `tsc` for a module resolver. Without one, write
a model oracle only when a naive implementation is correct by inspection and the
real one is optimized or clever. A model as intricate as the code under test is
not an oracle: write ordinary properties instead.

An oracle that is a library runs live in the test. An oracle that is a
subprocess or a network call runs once over generated inputs and its answers are
committed as a corpus, so the default suite stays fast and hermetic; keep the
live run as a separate opt-in target. Re-recording a corpus is a claim about
what the oracle does, never a way to turn a test green.

### End-to-end

Drive the real entry point - the CLI binary, the HTTP server, the app's UI -
with as much of the real code path as possible. Assert what the user sees: the
output, the exit code, the response status and body, the rendered screen. Cover
the common happy paths and, where practical, the common unhappy ones; boundary
cases belong to the unit layer.

Golden tests snapshot **user-facing output** - what the CLI prints, what the
API returns. Never snapshot an internal data structure, a debug dump or a
`Show` instance: that is an internals test with a bigger diff. A golden that
changed is a behavior change - work out whether it was intended before
re-recording, and read the diff of the re-recorded snapshot.

## Bugs are red first

When a bug appears in shipped behavior, reproduce it before fixing it: a failing
unit test, a new property the bug violates, and a failing end-to-end test -
every layer that can express it, naming the ones that cannot. At least one test
must be red before the fix, then fix and watch them all go green. A test written
after the fix that was never seen failing proves nothing about the bug.

The property must be a general property of the feature, not the single case
restated, because a bug is evidence that the spec was incomplete.

## Meaningless tests - delete them

A test that cannot fail when the behavior it names breaks is not a weak test,
it is a false one. Delete it, or rewrite it to assert the observable outcome:

- It asserts nothing, or only that the code ran without throwing when throwing
  was never the risk.
- It can never fail: the expectation is computed by the code under test, the
  assertion compares a value to itself, or the double returns the very value
  the test then expects.
- It is a tautology or a re-implementation: the expected value is computed with
  the same logic as the code.
- It duplicates another test: same behavior, same path, different name.
- It tests trivial code or constants: a getter, a constructor, a config value
  restated (`expect(MAX_RETRIES).toBe(3)`).
- It tests the framework or a library rather than our code: that the ORM saves,
  that the JSON encoder encodes.
- It pins internals: see *Black box*.

## Wrong tests - contradict the intent

A test can be well-formed and still wrong: it asserts behavior that contradicts
what the product or the change is meant to do. A test that expects the expired
session to be accepted, the old rounding the change set out to fix, or an error
the spec says must not happen is a proof of the wrong thing - worse than no
test, because it defends the bug.

- Read the test against the intent - the feature, the PR, the issue - not only
  against the code. Code and test can agree and both be wrong.
- A test may pin a known bug only when it says so in its name or a comment, and
  links what will fix it. Pinning a bug as correct without saying so is a wrong
  test.

## Never weaken an assertion

Loosening an assertion to make a red test green - a narrower check, a wider
tolerance, `toMatchObject` for `toEqual`, a skipped or deleted case, a
re-recorded golden nobody read - throws away the only thing the test was
protecting. A red test means the behavior changed: either the change is a bug,
fix the code; or the change is intended, update the expectation to the new
behavior and say so. Refactoring tests keeps every behavior they asserted
before.

## Placement

The code placement rule applies to tests. Fixtures, builders and doubles that
belong to one feature live with that feature; feature-agnostic ones belong in a
shared test directory, so they are reused instead of rewritten. Follow the
layout the project already uses for test files.
