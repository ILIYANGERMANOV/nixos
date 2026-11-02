# NixOS Configuration

Mono-repo for NixOS, nix-darwin, and dev-shell configs. Entry point: `flake.nix`.

## Directory Structure

```
flake.nix       - outputs: devShells, nixosConfigurations, darwinConfigurations
lib/            - system builder helpers (NixOS, Darwin, dev shells)
adapters/       - bind flake inputs to host-agnostic programs (agents.nix, claude-code.nix)
hosts/          - per-host identity (hostname, user)
modules/*.nix   - modules shared by NixOS and Darwin
modules/nixos/  - NixOS-only system configuration (server/ - software-factory only)
modules/macos/  - nix-darwin-only system configuration
modules/home/   - Home Manager configuration shared across all hosts
programs/       - reusable, host-agnostic program configs
programs/agents/- agent-agnostic config shared by every coding agent (instructions, skill catalog, subagent role records)
programs/tech-checks/ - `<tech>-<kind>` checks, treefmt
programs/shell-check/ - `writeShellApplication` and its rules
shells/         - dev shells (default for repo recipes, nixos-install, darwin-install)
secrets/        - sops-encrypted: common.yaml (global) + hosts/<hostname>.yaml
deslop/         - the architecture rules `deslop check .` enforces, and their baseline
.claude/rules/  - path-scoped detail for agents: each file's `paths:` says when it loads
```

## Reproducibility

**Config plus any prior state gives the same result on what Nix owns.
Everything else is untouched. Applying twice equals applying once.**

- Owned: Nix replaces it fully.
- Keyed: Nix sets only its keys in a file the tool also writes.
- Untouched: never written.

Effect scripts never branch on prior state or on run order. Details:
`.claude/rules/reproducibility.md`, loaded under `programs/` and `modules/`.

## Architecture

Imports flow one way: `flake.nix` -> `lib/` -> `modules/` and `shells/` ->
`adapters/` -> `programs/`. `just check` enforces it with
[Deslop](https://github.com/Ivy-Apps/deslop) against `deslop/rules/architecture.yaml`;
see `docs/adr/0008-deslop-enforces-the-architecture.md`.

### `programs/` - program logic lives here

Plain Nix functions (not NixOS/HM modules) returning an attrset of derivations.
They know nothing of hosts, users or activation, so home modules and dev shells reuse them.

### `modules/home/` - thin wiring into Home Manager

Each imports from `programs/` via the `root` special arg (the flake self) and wires
the derivations into HM options. Keep them minimal: logic belongs in `programs/`.

### `shells/` - dev shells

Import from `programs/` directly using `self`, composing the program configs home modules use.

### `hosts/` - identity only

Hostname and user only. All real configuration lives in `modules/`.

### `lib/` - system assembly

Compose inputs, modules and hosts into NixOS/Darwin systems.
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
`nix flake check` evaluates every host: never iterate with it.

1. A skill, subagent role or instruction `.md` edit: `nix build --no-link .#checks.x86_64-linux.agents`,
   `.#checks.x86_64-linux.claude-config` (size ceilings, `just skill-budget` prints them)
   and `.#checks.x86_64-linux.typos`, plus `python-tests` when the analyzer under
   its skill changed.
2. A `programs/<x>` edit: build that program's check - `claude-code`, `claude-config`,
   `python-tests` and `shell-embedded` for `programs/claude-code`, `shell-tests` for `programs/skills-link`, every
   `nvim-*` and `just tech lua` for `programs/nvim`, `nvim-kotlin` plus
   a `software-factory` host eval for `programs/kotlin`, `shell-tests`,
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
   `programs/agents/instructions/lead.md` say. Never after a docs-only edit, and never
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

**`programs/agents/` is the vendor-free frontend; each agent's own program is a
thin backend.**

Details: `.claude/rules/agents-frontend.md`, `agents-backend.md` and
`claude-code.md`, loaded under `programs/agents` and `programs/claude-code`;
why: `docs/adr/0011-agent-compiler.md`.

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
