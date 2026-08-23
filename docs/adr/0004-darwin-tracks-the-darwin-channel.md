# nixpkgs tracks the darwin channel, not nixos-26.05

`flake.nix` pins `github:NixOS/nixpkgs/nixpkgs-26.05-darwin`. That looks like a
typo for `nixos-26.05` and it is not. This records why, and what a CI guard is
doing next to it.

## What went wrong

`987b09a` bumped nixpkgs to `02e08985`. The rebuild started compiling Swift
5.10.1 and .NET's source-build VMR, which is hours of work on a laptop, so the
bump was reverted wholesale in `58f2f8e` - taking four unrelated tool updates
down with it.

The chain, from `nix why-depends`:

```
darwin-system → activation-<user> → home-manager-generation → home-manager-path
  → pre-commit-4.5.1            (modules/home/git.nix)
    → dotnet-sdk-wrapped-8.0.423
      → dotnet-vmr-8.0.29
        → swift-wrapper-5.10.1
```

nixpkgs' `pre-commit` carries `dotnet-sdk` in its `nativeCheckInputs`, because
its test suite exercises dotnet hooks, and darwin's `dotnet-vmr` is built with
Swift. None of that is in pre-commit's *runtime* closure, so it costs nothing at
all - right up until `pre-commit` itself has to be built from source. Then the
whole tail comes with it.

`herdr` was the initial suspect and was not the cause. It does rebuild on every
bump, because `inputs.nixpkgs.follows = "nixpkgs"` makes its derivation hash
unique to our pin so no upstream artifact can ever match it, but it is a Rust
TUI and a zig `libghostty-vt` cache: minutes.

## Why the rev had no binaries

`cache.nixos.org` for `pre-commit-4.5.1` on aarch64-darwin:

| nixpkgs rev | store path | narinfo |
| --- | --- | --- |
| `531670d` (before the bump) | `yd00x54l...` | 200 |
| `02e08985` (the bump) | `891ky604...` | **404** |
| `b18a4b9` (the next proposal) | `yy35ziav...` | 200 |

`nixos-26.05` and `nixpkgs-26.05-darwin` both fast-forward along
`release-26.05`, but different Hydra jobsets advance them: the NixOS/Linux
jobset advances the first, the darwin jobset the second. They land on different
revisions. So a rev taken from `nixos-26.05` is guaranteed to have *Linux*
binaries and merely tends to have darwin ones. `02e08985` is an ancestor of both
branches yet was never a darwin channel head, so its darwin closure was never
built. Nine days later it is still a 404: this is not Hydra lag that resolves
itself.

Tracking the darwin channel makes the guarantee match the machine that consumes
it. Every rev dependabot can now propose is one the darwin jobset actually
evaluated.

## Why there is a guard as well

The channel switch removes the common case, not every case. A package can still
fail to build in the darwin jobset, and anything reachable only through our own
flake inputs was never in any jobset. `just darwin-cache-check` dry-runs the
`macos-main` closure and fails on a denylist of derivations that cost hours:
Swift, .NET, the GHC/HLS set, LLVM, browser engines. It runs on the Linux CI
runner, because `--dry-run` only queries substituters and never needs a darwin
builder.

The denylist is `just/nix-darwin/expensive-builds.deny`, a plain
pattern-per-line file meant to be edited by hand. Two traps are recorded in it:
patterns must be anchored, or `go-1\.` also matches
car`go-1.9`6.1-aarch64-apple-darwin, and nixpkgs' own `rustc`/`cargo` must be
distinguished from the rust-overlay toolchain herdr pulls in, which is only a
tarball unpack and is built every single time.

Both of the guard's failure modes are silent - a denylist that matches nothing
and an extractor that yields nothing both report every plan as clean - so the
recipe runs its own pipeline over a synthetic plan with known answers before it
will vouch for a real one. That self-test earned its place immediately: the
first version terminated its range on `/will be fetched:/` while nix actually
prints `will be fetched (3.3 GiB download, ...):`, so the fetch list was being
scanned as if it were the build list.

## Consequences

`lenovo-old` now rides on a nixpkgs branch validated for darwin rather than for
Linux, and may see cache misses of its own. That was accepted deliberately
rather than solved: the alternative is a second nixpkgs input plus per-system
`follows` for every shared flake, which doubles the lock to serve a machine that
is rebuilt rarely. `docs/NON-DARWIN-NIXOS-ISSUES.md` tracks what to do if it
starts hurting.

`modules/home/languages/haskell.nix` hard-pins `haskell.packages.ghc9103`. That
is currently also nixpkgs' default `haskellPackages` compiler, which is the only
reason HLS is a cache hit. When nixpkgs moves its default, that set leaves the
Hydra-built path and HLS gets built from source - a worse outcome than the Swift
one, since it is the entire Haskell package set. The denylist covers it, so the
guard will say so rather than the laptop discovering it.

Dependabot is split into a `nixpkgs-core` group and a `tools` group for the same
reason the revert hurt: with one group, a nixpkgs rev the guard rejects also
holds back herdr, llm-agents and the skills.
