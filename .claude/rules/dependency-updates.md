---
paths:
  - "flake.nix"
  - "flake.lock"
  - "modules/nix.nix"
  - "just/nix-darwin/**"
  - ".github/dependabot.yml"
  - ".github/workflows/**"
  - "docs/adr/0004-*"
  - "docs/NON-DARWIN-NIXOS-ISSUES.md"
---

## Dependency Updates

**`nixpkgs` tracks `nixpkgs-26.05-darwin`, not `nixos-26.05`. That is deliberate - do not "fix" it.**

Both branches fast-forward along `release-26.05`, but different Hydra jobsets advance them, so they land on different revisions. A rev from `nixos-26.05` is guaranteed to have *Linux* binaries in `cache.nixos.org`; darwin coverage is incidental. One such rev cost hours of Swift and .NET compilation and had to be reverted (`987b09a` → `58f2f8e`). See `docs/adr/0004-darwin-tracks-the-darwin-channel.md`; `lenovo-old`'s side of that trade is tracked in `docs/NON-DARWIN-NIXOS-ISSUES.md`.

`just darwin-cache-check` dry-runs the `macos-main` closure and fails if anything in `just/nix-darwin/expensive-builds.deny` would be built locally. Run it before pulling a dependency bump; CI runs it on every PR in the `cache-guard` job. It runs on Linux because `--dry-run` only queries substituters and never needs a darwin builder, but the substituter list in the workflow must stay in sync with `modules/nix.nix`, or it reports false misses.

The denylist is a plain pattern-per-line file, edited by hand. Anchor every pattern with `^`: unanchored, `go-1\.` also matches car`go-1.9`6.1-aarch64-apple-darwin, which herdr's rust-overlay toolchain builds every time. The recipe self-tests its own pipeline against a synthetic plan before trusting a real one, because both of its failure modes report a bad plan as clean.

Dependabot splits nix inputs into `nixpkgs-core` (guard-gated), `ai` (agent tooling and skill sources) and `ungrouped` (a catch-all matching everything else), so a nixpkgs rev the guard rejects does not also hold back herdr, llm-agents and the skills, and an input nobody classified still gets updates instead of silently freezing. `ungrouped` restates the other two memberships in `exclude-patterns` because dependabot has no group-reference syntax; keep them in step.
