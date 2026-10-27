# Deslop enforces the architecture, and adapters get their own layer

`CLAUDE.md` describes a layering - hosts are identity only, programs are
host-agnostic, lib assembles systems - that nothing checked. It held by
discipline, and drifted in small ways nobody noticed: `lib/claude-code.nix` was
imported by modules and shells, and two programs reached into each other's
files. [Deslop](https://github.com/Ivy-Apps/deslop) reads every path literal in
the repo as an import edge and checks the resulting graph against
`deslop/rules/architecture.yaml`. `just check` runs `deslop check .`, so CI
fails on a violation. Issue #211 holds the original rulebook and findings.

## `adapters/` is a layer, not part of `lib/`

`lib/agents.nix` and `lib/claude-code.nix` do not assemble systems. They take
`inputs`, pick what a program needs from them (`llm-agents`' `claude-code`, the
`flake = false` skill sources) and call the program's `default.nix`. Modules
and shells import them, so leaving them in `lib/` made `lib` both the top and a
middle layer, and `lib -> modules -> lib` a loop at directory level.

They now live in `adapters/`, and the flow is one way:

```
flake.nix -> lib/ -> modules/, shells/ -> adapters/ -> programs/
```

`lib-is-private-to-the-flake` keeps `lib/` to `flake.nix`, and
`adapters-are-thin` allows an adapter to import only flake inputs, other
adapters and a program's `default.nix`. Narrowing the lib rule to
`lib/default` instead was rejected: it would have kept the loop and given the
glue no rule of its own.

## Packaged from the npm platform tarball

Upstream ships no Nix package. Its npm package is a wrapper that dispatches to
`@ivy-apps/deslop-<platform>`, which holds one static binary, so
`programs/deslop` fetches that tarball directly with a pinned hash per system.
Bumping it means changing `version` and the three hashes.

## Consequences

- **Dynamic paths cannot be judged.** `builtins.readDir dir` in
  `programs/agents/skills/lib.nix` and `builtins.readFile script` in
  `programs/software-factory` name no file Deslop can resolve. They are accepted
  in `deslop/baseline.yaml`, which is regenerated with `deslop baseline .`,
  never edited by hand. A new dynamic path fails the check until it is
  baselined, which is the point: someone looks at it.
- **`deslop/rules/` holds only rule files.** Anything else there, a README
  included, breaks rule loading.
- **Known over-approximation.** `${hostname}` in lib's builders expands to every
  host directory, so lib appears to import the macOS hosts from
  `mkNixosSystem` too. No rule is affected by it.
- **Deslop cannot express "must be imported by"**, so an orphan host or module
  goes unnoticed.
- **The graph is browsable.** `deslop explore .` writes
  `deslop/diagram/index.html` (gitignored). CI publishes it to GitHub Pages:
  `main` at the site root, each same-repository pull request under `pr/<n>/`.
