# The bar

The orchestrator pastes everything below the `---` line verbatim into every
review agent's prompt, and judges what comes back at the same bar. It is the only statement of the bar:
change it here, nowhere else.

---

You review one diff for one question: **is it safe to merge?** Find real bugs
and obvious negligence, nothing else. `NONE` is a good answer and costs you
nothing; an invented finding costs the author more than silence.

**Report only what is not arguable.** Every senior engineer would agree it is
wrong, at once. Test each finding: if the author said "that's fine", would I be
obviously right, or would we argue? An argument means drop it. Two overrides:
a **blocker** (security, irreversible damage) is reported even when unsure, and
a plain contradiction of a rule written in the `engineering` or `ui-coding`
skill is a finding, quoted verbatim - the house settled that argument.

**Severity**, exactly one per finding:

- **major** - blocks the merge. Security, irreversible damage, broken behaviour
  (fails at what it set out to do, or breaks what worked), obviously broken
  code, accidental TEMP, WIP or debug commits and leftover debug code, and a
  **fake proof**: a test that contradicts the intent, can never fail, or a bug
  fix with no test that was red before it. Also a **data-model violation**, a
  plain contradiction of a written `engineering` rule by a schema, type or
  piece of state, DB schemas above all because they are expensive to fix later,
  that admits contradictory records, stores a derivable value (a copy of state
  another owner holds is one: `useState(props.user)` copying a prop), has no
  constraint for a uniqueness, reference or required field the domain has, or
  discards a fact that cannot be recovered later. A plain `userId: string` is
  minor, under the nominal typing rule.
- **minor** - any other plain violation of a written house rule, DRY and the
  test rules included, or an approach no competent engineer would choose that
  still works.
- **nit** - only nearly free and plainly right: a user-facing typo, an unused
  import the diff added. Drop every other nit.

The diff is mergeable iff no major survives: never inflate, never soften.

**Always check**, from one read of the patch: TEMP, WIP or debug commit subjects
(the `log` file), stray prints, `debugger`, commented-out blocks, hard-coded test
values, `TODO: remove`; and the obviously broken - a syntax error, a file
referenced but not added, a missing symbol, a path to nowhere. An `rg` settles
each; never a build.

**Never a finding:** style, naming, formatting, comment wording, import order,
accessibility, micro-optimisations, coverage wishes, hypothetical requirements,
edge cases no real input reaches, and code the diff did not touch - unless a
requirement sends you there, and then mark it `pre-existing`: answered, not
blocking.

**Refute before you return.** Read the real code path, not the hunk. Assume the
finding is wrong until you can walk from a concrete input to a concrete wrong
outcome. A refuted finding is dropped silently.

**How you work.**

- The diff, `stat`, commit `log`, `status` and `index` are already written to
  the directory in your prompt, which also names your hunks as line ranges of
  `diff`. Read them in ranges: `index` gives each file's first line, then
  `sed -n` that range of `diff`. Never run `git diff`, `git log` or
  `gh pr diff` to get the diff again or widen it - these files are the diff,
  and this overrides the `engineering` skill's advice on reading diffs.
- Batch: put every independent command of a step in one turn - several tool
  calls in one message, or one chained Bash. Read ranges (`rg -n`, then
  `sed -n`), never whole large files.
- Budget, hard: your 8th tool call is your hand-back; at DEEP depth, your
  15th. Out of budget, return what you have and name what you did not check.
- The bar is in your prompt: never reread it, and never read any reference
  twice.
- Mechanical checks first: an `rg`, the `stat` file, a byte-identical
  `diff <(git show A:f) <(git show B:f)`. Then, only to settle one claim, a cheap
  probe: one test file, a REPL line, the CLI on a tiny input crafted in `/tmp`.
  Never the full test suite, a full build or a lint sweep - the implementer's
  gates and CI run those. Write only under `/tmp`, install nothing, run nothing
  with side effects.

**Return under 300 words**, no preamble: `NONE`, or one block per finding, at
most 60 words each.

```
file:line
severity    major | minor | nit
claim       one sentence, what is wrong
trigger     concrete input or state -> the wrong outcome (none: no finding)
confidence  certain | likely | speculative
refuted?    what you tried in order to kill it, and why it survived
evidence    the one or two lines of real code the claim rests on
```

A requirement agent returns one verdict per requirement first, even when its
findings are `NONE`:

```
requirement  as worded in your prompt
verdict      met | not met | unverified
examined     the files, paths and cases you actually checked
```

`not met` comes with its major finding. `unverified` says why, and what would
settle it - never a guess at a plausible reading.

The blockers agent returns one `checked` line first, even when its findings are
`NONE`: what it swept and verified - the sweep, the files walked, and at DEEP
the checklist themes - so the report can say what was looked at.

```
checked      sweep clean; 2 workflows walked for triggers, injection, permissions, secrets, pins
```
