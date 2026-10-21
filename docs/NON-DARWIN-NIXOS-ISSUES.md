# Non-darwin (NixOS) issues

Open items for `lenovo-old` created by decisions taken for the macOS hosts.
Nothing here is known to be broken - these are consequences that were accepted
without being measured, because macOS is the daily driver and the NixOS box is
rebuilt rarely.

Context: `docs/adr/0004-darwin-tracks-the-darwin-channel.md`.

## The single nixpkgs input now tracks the darwin channel

`flake.nix` pins `github:NixOS/nixpkgs/nixpkgs-26.05-darwin`. Both hosts share
that one input, so `lenovo-old` is built from a branch whose revisions were
chosen by Hydra's *darwin* jobset. `nixos-26.05` and `nixpkgs-26.05-darwin` both
fast-forward along `release-26.05` but land on different revisions, so an
x86_64-linux closure at a darwin channel head has no guarantee of being in
`cache.nixos.org` - the mirror image of the problem this fixed for macOS.

- [ ] Measure it. On any machine:
      `nix build --dry-run .#nixosConfigurations.lenovo-old.config.system.build.toplevel`
      and read the "will be built" list. `--dry-run` only queries substituters,
      so this needs no Linux builder and can run from macOS.
      `software-factory` (x86_64-linux, headless) was measured with
      `just factory-cache-check` on the 2026-09-26 pin: the only expensive
      local build was `nodejs-24.21.0`, from `languages/typescript.nix`.
- [ ] If the list is small and cheap, close this out and record the number here.
- [x] The guard is factored out as the private `_cache-check` recipe in
      `just/nix-darwin/cache-check.just`; `factory-cache-check` uses it. A
      `nixos-cache-check` for `lenovo-old` is one more line.
- [ ] Only if the misses are genuinely expensive: split the input. Add
      `nixpkgs-linux.url = "github:NixOS/nixpkgs/nixos-26.05"`, have
      `mkNixosSystem` pass it as `nixpkgs.pkgs`, and repoint the `follows` of
      every flake the NixOS host uses (`home-manager`, `disko`, `sops-nix`,
      `lanzaboote`). This roughly doubles the lock and the eval cost, which is
      why it was not done up front.

## Secondary

- [ ] `lanzaboote` is excluded from dependabot (`.github/dependabot.yml`) and is
      pinned to the `v1.0.0` tag. It only matters for secure boot on
      `lenovo-old`. Decide whether that pin should ever move, or make the reason
      for freezing it explicit in `flake.nix`.
- [ ] `nix flake check` evaluates `lenovo-old` ("checking NixOS configuration
      'nixosConfigurations.lenovo-old'"), so breakage there is caught. It does
      *not* descend into `darwinConfigurations`, which is not an output type it
      knows - the darwin hosts are only evaluated because
      `just darwin-cache-check` builds a plan for `macos-main`. Nothing
      evaluates `macos-work`, though it shares every module with `macos-main`.
