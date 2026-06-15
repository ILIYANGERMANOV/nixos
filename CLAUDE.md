# NixOS Configuration

Mono-repo for NixOS, nix-darwin, and dev-shell configs. Entry point: `flake.nix`.

## Directory Structure

```
flake.nix       — outputs: devShells, nixosConfigurations, darwinConfigurations
lib/            — system builder helpers (NixOS, Darwin, dev shells)
hosts/          — per-host identity (hostname, user)
modules/*.nix   — cross-platform modules imported by both NixOS and Darwin (e.g. nix.nix, home-manager.nix, theme.nix)
modules/nixos/  — NixOS-only system configuration
modules/macos/  — nix-darwin-only system configuration
modules/home/   — Home Manager configuration shared across all hosts
programs/       — reusable, host-agnostic program configs
shells/         — dev shells (web, haskell, nixos-install)
```

## Architecture

### `programs/` — program logic lives here

Plain Nix functions (not NixOS/HM modules) that build derivations and return an attrset.
They know nothing about hosts, users, or activation — just packages and configuration artifacts.

Designed for reuse: the same program config can be consumed by home modules and dev shells alike.

### `modules/home/` — thin wiring into Home Manager

Each module imports from `programs/` via the `root` special arg (the flake self) and wires the resulting derivations into HM options (`home.packages`, `home.activation`, etc.).
Keep these minimal — business logic belongs in `programs/`.

### `shells/` — dev shells

Import from `programs/` directly using `self`, composing the same program configs used by home modules into standalone developer environments.

### `hosts/` — identity only

Hosts declare only their hostname and user identity. All real configuration lives in `modules/`.

### `lib/` — system assembly

Helpers that compose inputs, modules, and hosts into complete NixOS/Darwin system configurations.

## Adding a New Program

1. Create `programs/<name>/default.nix` as a plain function returning an attrset of derivations.
2. Create `modules/home/<name>.nix` as a thin HM wrapper that imports it via `root`.
3. Register the HM module in `modules/home/default.nix`.
4. Optionally import `programs/<name>` directly in any `shells/` that need it.

## Neovim + LSP Architecture

**Neovim owns LSP client config. Project dev shells own LSP binaries.**

- `programs/nvim/languages/*.nix` — LSP client config only (`package = null` on all servers except `nil_ls`). No `extraPackages` for language tooling.
- `modules/home/languages/*.nix` — global LSP binaries and dev tools installed via Home Manager (e.g. `hls`, `fourmolu`, `typescript-language-server`).
- `nil_ls` is the only LSP with its binary baked into Neovim — Nix files have no project dev shell.

**direnv** (enabled in `modules/home/default.nix` via `programs.direnv.nix-direnv`) auto-activates a project's dev shell on `cd`. Project flakes only need a `.envrc` containing `use flake`. This puts project-pinned LSP binaries (e.g. GHC-matched HLS) on PATH, which Neovim's lspconfig picks up automatically.

Project flakes have **no dependency on this nixos repo** — they are standalone.

**Context-aware keymaps** (`programs/nvim/core/context-aware-keymaps.nix`) provide a single `<leader>tt` that dispatches to the right test runner at runtime. The registry (`_G.ContextRunners`) is initialized in `extraConfigLuaPre` (runs before all plugin/language Lua) to avoid ordering issues. Each language file registers its runner via `_G.RegisterContextRunner` in `extraConfigLua`.
