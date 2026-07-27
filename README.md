# My NixOS (experimental toy project)

Personal nix-darwin / NixOS configuration for macOS-first development. Primary machine runs nix-darwin; there is a secondary NixOS host. Everything is managed with Home Manager.

---

> [!WARNING]
> ## SECURITY DISCLAIMER & PERSONAL USE NOTICE
>
> **This repository is my personal, experimental NixOS and NixVim configuration. It is NOT intended for production use, public deployment, or adoption by others.**
>
> - **USE AT YOUR OWN RISK.** This configuration may contain security vulnerabilities, incomplete hardening, experimental settings, or unsafe defaults that are intentionally or unintentionally present for my own convenience during development.
> - **NO WARRANTY.** I make absolutely no guarantees about the correctness, safety, or stability of anything in this repository. Configurations may break your system, expose sensitive data, or behave in unexpected ways.
> - **NOT SECURITY-AUDITED.** SOPS secrets management, disk encryption settings, SSH configuration, and any other security-sensitive components have NOT been independently audited. Do not assume they are safe or correct.
> - **NOT MAINTAINED FOR OTHERS.** This repo evolves for my personal needs. Breaking changes, incomplete states, and half-finished experiments are normal and expected.
> - **DO NOT USE THIS ON PRODUCTION SYSTEMS.** This is a lab/experimentation environment. It is explicitly not designed to be reproducible, secure, or safe outside of my own machines.
>
> If you are looking for a well-maintained, production-safe NixOS configuration, please look elsewhere. See the [LICENSE](./LICENSE) for full liability disclaimers.

---

## Key Programs

**NixVim** — `programs/nvim/`  
Full Neovim config via NixVim. LSP client config lives in `programs/nvim/languages/`; language binaries are installed via `modules/home/languages/`. Supports Haskell, TypeScript, Elixir, Nix, D2, YAML, and MDC.

**Claude Code** — `programs/claude-code/`  
Three flavors (`claude`, `claude-ts`, `claude-web-ui`) with shared base settings, MCP server wiring, and a custom statusline binary. Each flavor wraps the `claude` CLI and writes `~/.claude/settings.json` at launch.

**Ghostty** — `modules/home/terminal.nix`  
Terminal with TokyoNight theme, JetBrains Mono Nerd Font, and zsh + Starship + fzf / zoxide / eza / ripgrep.

---

## Directory Structure

```
flake.nix           — outputs: devShells, nixosConfigurations, darwinConfigurations
hosts/              — per-host identity (hostname, user)
  macos-main/       — primary nix-darwin machine
  macos-work/       — secondary nix-darwin machine
  lenovo-old/       — legacy NixOS machine
lib/                — system builder helpers (NixOS, Darwin, dev shells)
modules/
  home/             — Home Manager modules (thin wiring into programs/)
  macos/            — nix-darwin system-level config
  nixos/            — NixOS system-level config
programs/
  nvim/             — NixVim Neovim config (core/, languages/)
  claude-code/      — Claude Code flavors + statusline
shells/             — dev shells for install workflows
docs/               — setup and operations guides
just/               — Justfile recipes
```

---

## Docs

| Doc | Purpose |
|-----|---------|
| [docs/nix-darwin-install.md](docs/nix-darwin-install.md) | Bootstrap nix-darwin on a new Mac (primary path) |
| [docs/nixos-install.md](docs/nixos-install.md) | Bootstrap NixOS on bare metal |
| [docs/SOPS.md](docs/SOPS.md) | Secrets management with SOPS + age |

---

## Common Commands

```shell
# Lint Nix files
just lint

# Format Nix files (nixfmt)
just format

# Lint + format check + flake check
just check

# Rebuild and switch (macOS)
darwin-rebuild switch --flake .#macos-main

# Rebuild and switch (NixOS)
nixos-rebuild switch --flake .#lenovo-old
```
