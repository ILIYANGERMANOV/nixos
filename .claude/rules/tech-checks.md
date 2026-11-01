---
paths:
  - "programs/**"
  - "modules/**"
  - "shells/**"
  - "just/**"
  - "Justfile"
  - ".github/**"
  - "docs/adr/0009-*"
---

## Tech checks

The ladder's `x86_64-linux` is the box; CI covers both `x86_64-linux` and
`aarch64-linux`.

`nix develop -c just tech <name>` takes under a minute and evaluates no host: `shell`
for a `.sh`, a `.bats`, a recipe or a workflow, `python` for a script (ruff,
basedpyright and pytest: a test is `test_<name>.py` beside `<name>.py`, keeping the
name literal, such as `test_read-guard.py`). It builds every `<name>-*` flake check
for this system. It prints `All good (N)` and exits 0, or
the failures verbatim and exits nonzero, so never pipe it through `grep`, and
never run its tools by hand before it. A name with no checks fails. It sees only
files git tracks, so `git add -N` a new file first.

A lint, type or test check for a technology rather than a program is
`<tech>-<kind>` in `programs/tech-checks/`, such as `shell-lint`; a new
`<tech>` also joins the `tech` matrix in `check.yml`. See
`docs/adr/0009-tech-checks.md`.

A script uses `writeShellApplication` from `programs/shell-check`, never
`pkgs.writeShellApplication`.
A just recipe has no `{{ }}` on a sudo line: use an exported parameter.
A `.sh` spliced into a script opens with a `# shellcheck shell=bash` directive,
which `fragment` in `programs/shell-check` cuts on assembly: mid-script it
would silence the next function.
A just recipe over 30 lines moves to a `.sh`. A shell string in Nix over 5 lines
moves to a `.sh` read in with `readFile` or `fragment`. `shell-limits` enforces
both.
