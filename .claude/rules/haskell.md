---
paths:
  - "**/*.hs"
  - "**/*.cabal"
  - "programs/haskell/**"
---

## Haskell (`programs/haskell`, the kernel in `programs/agents/kernel`)

Check ladder, fastest first. Stop at the rung that covers the edit:

| Rung | What it does |
|---|---|
| `nix run .#kernel-quick-typecheck` | Reloads a warm per-worktree ghcid session: under 2s warm, ~30s cold. Exit 0 green, 1 GHC errors, 2 no verdict |
| `nix run .#kernel-quick-test -- <match>` | Runs the hspec examples `--match` selects in that session. Fails when none match. No match given: `kernel-test` |
| `nix run .#kernel-test [-- <match>]` | `cabal test` of the suite, fixed seed |
| `nix run .#kernel-lint` | hlint, `fourmolu --mode check`, `cabal-fmt --check` (`kernel-format` fixes the last two) |
| `nix develop -c just tech haskell` | The Nix build that runs the suite, the lint check and the runners' shellcheck |
| `just check` | Once, at the end |

`kernel-build` is `cabal build all`. `just kernel <runner> <args>` is the same
as `nix run .#kernel-<runner> -- <args>`.

Caveats:

- An E2E spec in `quick-test` runs the executable from the last cabal build.
  After an `app/` edit, run `kernel-build` (or `kernel-test`) first.
- An idle ghcid session dies after 2h; the next quick call respawns it
  (a cold start is a full load).
- The quick runners take `nix`, `git` and `pgrep` from PATH.

In the kernel, a spec is `test/<Module>Spec.hs`, found by hspec-discover but
also listed in `state.cabal`; a new dependency goes in both `state.cabal` and
`default.nix`. A golden file under `test/golden` is never created by the
check: a missing one fails.

A new Haskell package gets the whole toolset from one call in its
`default.nix`, as `programs/agents/kernel/default.nix` does:

```nix
tooling = haskell.mkPackage {
  name = "foo";            # runners are foo-quick-typecheck, foo-test, ...
  package = unwrapped;     # the haskellPackages derivation
  dir = "programs/foo";    # from the repo root
  testSuite = "foo-test";
  executables = [ "foo" ]; # optional
  testEnv = { env = { }; bins = { }; }; # optional
};
```

Then wire it in `flake.nix` like `kernelDev`: `tooling.apps` into `apps`,
`tooling.shell` as `devShells.foo` (the quick runners enter it), and
`tooling.lint` plus `linkFarmFromDrvs` of `tooling.scripts` into
`programs/tech-checks/haskell.nix`. Never name the passthru attribute `dev`:
stdenv reads a dependency's `dev` as its dev output.
