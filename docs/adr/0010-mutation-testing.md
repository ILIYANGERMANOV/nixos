# Mutation testing lists the changed lines no test protects

A passing test suite says the code ran, not that a test would notice it breaking.
Mutation testing changes the code one small edit at a time (a mutant) and runs
the tests: a mutant no test fails on is a line nobody checks. This ADR records
how it runs here and what it cannot see.

## How to run it

| Command | Mutates |
|---|---|
| `just mutation-diff [base]` | The lines added or edited since the merge-base with `base` (default `origin/main`) |
| `just mutation` | Everything in scope |

Both write `.mutation/mutation-diff.json` (schema 1 of the shared contract) and
`.mutation/mutation-diff.md`, print the markdown and end with the JSON's path.
Tool output goes to `.mutation/mutation.log`. Only survived, uncovered and timed
out mutants are listed. The exit code is nonzero only when the run itself fails,
so a survivor is never a failure.

A Python mutant's `operator` is mutmut's mutant id, as mutmut names no operator.
`mutmut show <id>`, from `.mutation/python`, prints its diff.

## Scope

- Python, by mutmut: the six modules whose tests import them, listed in
  `PYTHON_MODULES` in `programs/mutation/mutation_diff.py`.
- TypeScript, by Stryker: `kit/index.ts` and `wallet/index.ts` under
  `programs/playwright`. The rest there is Playwright drivers, which only `qa` runs.

## What it does not cover

- Shell is deferred to later work, and Nix is not mutated.
- Code its tests reach only through a subprocess shows as uncovered, as no
  mutant there can be killed: the guards, the statusline, most of `analyze.py`,
  whose tests run its CLI, and `cache_check`'s `main`.
- Deleted lines and test-only diffs are not assessed, and the report says so.

## Advisory, outside the checks

A full run takes minutes, so no `checks` derivation runs it, and neither do
`just check`, `just quick-check` or `nix flake check`.

`mutation.yml` runs it in CI and fails nothing on a pull request:

- A pull request runs `just mutation-diff` against its own base branch, so a
  stacked one diffs against its parent. The weekly and manual runs are full,
  and fail when the run does.
- A PR gets one comment, updated on each push. A separate job holding only
  `pull-requests: write` renders it from the JSON, never from PR-built markdown,
  and checks nothing out. It skips forks and Dependabot.
- The artifact `mutation-diff` holds both files uncut, and the comment gives its
  `gh run download` line.
