# NixOS Configuration

Mono-repo for NixOS, nix-darwin, and dev-shell configs. Entry point: `flake.nix`.

## Directory Structure

```
flake.nix       — outputs: devShells, nixosConfigurations, darwinConfigurations
lib/            — system builder helpers (NixOS, Darwin, dev shells)
adapters/       - bind flake inputs to host-agnostic programs (agents.nix, claude-code.nix)
hosts/          — per-host identity (hostname, user)
modules/*.nix   — cross-platform modules imported by both NixOS and Darwin (e.g. nix.nix, home-manager.nix, theme.nix, secrets.nix)
modules/nixos/  — NixOS-only system configuration (server/ - software-factory only)
modules/macos/  — nix-darwin-only system configuration
modules/home/   — Home Manager configuration shared across all hosts
programs/       — reusable, host-agnostic program configs
programs/agents/— agent-agnostic config shared by every coding agent (AGENTS.md, skill and subagent catalogs)
programs/tech-checks/ - `<tech>-<kind>` checks, treefmt
programs/shell-check/ - `writeShellApplication` and its rules
shells/         — dev shells (default for repo recipes, nixos-install, darwin-install)
secrets/        — sops-encrypted: common.yaml (global) + hosts/<hostname>.yaml
deslop/         - the architecture rules `deslop check .` enforces, and their baseline
.claude/rules/  - path-scoped detail for agents: each file's `paths:` says when it loads
```

## Architecture

Imports flow one way: `flake.nix` -> `lib/` -> `modules/` and `shells/` ->
`adapters/` -> `programs/`. `just check` enforces it with
[Deslop](https://github.com/Ivy-Apps/deslop) against `deslop/rules/architecture.yaml`;
see `docs/adr/0008-deslop-enforces-the-architecture.md`.

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
Only `flake.nix` imports `lib/`; everything else is handed what it needs.

### `adapters/` - flake inputs into programs

A program never sees `inputs`, so an adapter does the binding: it takes
`inputs`, picks the packages and `flake = false` sources a program needs, and
calls that program's `default.nix`. Nothing else - no logic, no other imports.
`modules/` and `shells/` import an adapter instead of the program when the
program needs a flake input.

## Adding a New Program

1. Create `programs/<name>/default.nix` as a plain function returning an attrset of derivations.
2. Create `modules/home/<name>.nix` as a thin HM wrapper that imports it via `root`.
3. Register the HM module in `modules/home/default.nix`.
4. Optionally import `programs/<name>` directly in any `shells/` that need it.

## Checks

**Run the narrowest rung that covers the edit; `just check` runs once, at the end.**
`nix flake check` spends most of its time evaluating every host, so it is the
wrong tool for iterating.

1. A skill, subagent or instruction `.md` edit: `nix build --no-link .#checks.x86_64-linux.agents`,
   `.#checks.x86_64-linux.claude-config` (size ceilings, `just skill-budget` prints them)
   and `.#checks.x86_64-linux.typos`, plus `self-improve` when the analyzer under
   its skill changed.
2. A `programs/<x>` edit: build that program's check - `claude-code`, `claude-config`,
   `claude-bash-guards` and `shell-embedded` for `programs/claude-code`, `software-factory` for `programs/skills-link`, `nvim-search`,
   `nvim-typescript`, `nvim-kotlin` and `just tech lua` for `programs/nvim`, `nvim-kotlin` plus
   a `software-factory` host eval for `programs/kotlin`, `software-factory`,
   `playwright`, `qa` (Linux only) and `just tech ts` for `programs/playwright`, `typos` - as `nix build --no-link .#checks.x86_64-linux.<name>`.
3. A `modules/` or `hosts/` edit: evaluate the touched host only, with
   `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
   (`lenovo-old`, `software-factory`) or
   `nix eval --raw .#darwinConfigurations.<host>.system.drvPath` (`macos-main`, `macos-work`).
   An added, moved or re-pointed import: `nix develop -c just architecture`.
4. A `.github/` edit: `nix build --no-link .#checks.x86_64-linux.zizmor` and
   `just tech shell`.
5. A script or recipe: `nix develop -c just tech <name>` (`shell`, `python`).
6. `just quick-check` before handing back mid-work: lint, architecture, format and every
   `checks` derivation for this system. On Linux that evaluates one host, for
   `software-factory-activation`.
7. `just check` once on the final state, run as the Checks rules in
   `programs/agents/AGENTS.md` say. Never after a docs-only edit, and never
   with a build, lint or test chained in front of it.

## Dependency Updates

**`nixpkgs` tracks `nixpkgs-26.05-darwin`, not `nixos-26.05`. That is deliberate - do not "fix" it.**

Details: `.claude/rules/dependency-updates.md`, loaded when touching the flake.

## Secrets

**`myConfig.secrets` is the only door to `sops.secrets`. Never write
`sops.secrets` by hand.**

**Paths only, never values.** `builtins.readFile` on a decrypted path bakes plaintext into the world-readable store.

Details: `.claude/rules/secrets.md`, loaded when touching secrets or modules that
declare them.

## Agent Configuration

**`programs/agents/` is agent-agnostic. Agent-specific code lives in that
agent's own program.**

Details: `.claude/rules/agent-configuration.md`, loaded under `programs/agents`,
`programs/claude-code` and `adapters/`. Read it before editing the skill catalog,
the subagent catalog or a flavor.

## Software factory

**`software-factory` is a headless server whose agents are driven from a phone
via Claude Code Remote Control. Its configuration must never change another
host.**

Details: `.claude/rules/software-factory.md`, loaded under
`programs/software-factory`, `modules/nixos/server` and `modules/home/factory`.
This repository is public: no IP addresses, tailnet names or private repository
names, ever.

## Neovim

Neovim, LSP and picker rules live in `programs/nvim/CLAUDE.md`. It loads for work
under `programs/nvim`; read it before editing `modules/home/languages/`.
