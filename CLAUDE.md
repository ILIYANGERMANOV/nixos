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
programs/skills/— agent skill catalog (custom/ holds committed SKILL.md files)
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

## Agent Skills

**`programs/skills/` owns the catalog. The Claude flavor wrappers own the disk.**

- `programs/skills/default.nix` — the catalog: third-party sources with an
  explicit allowlist and rename map, plus the list of enabled custom skills.
- `programs/skills/lib.nix` — discovery, collision detection, rename, farm and
  validation. No policy.
- `programs/skills/custom/<name>/SKILL.md` — hand-written skills, committed. A
  directory is only installed once its name is added to `custom`, so drafts can
  stay in version control. See `programs/skills/custom/README.md`.
- `lib/skills.nix` — adapter that injects `flake = false` inputs as
  `externalSrcs`, mirroring `lib/claude-code.nix`.

External sets are pinned as flake inputs rather than `fetchFromGitHub`. That is
deliberate: `modules/nix.nix` sets `allow-import-from-derivation = false`, so a
fetched derivation could not be `readDir`'d, but a flake input is a plain store
path and can be — which is what lets the allowlist use bare skill names that are
searched for recursively.

`~/.claude/skills` is **not** Home Manager managed. Each flavor wrapper wipes and
relinks it at launch from its own `linkFarm`, so switching flavors never leaves a
stale skill behind — the same pattern `mkClaudeFlavor` already uses for
`settings.json` and `.mcpServers`. Anything hand-placed there is destroyed on the
next launch; prototype in a project's `.claude/skills/` instead.

Skills are assigned with `baseSkills` (shared by every flavor, declared in
`programs/claude-code/default.nix`) plus per-flavor `extraSkills`.

`nix flake check` — and therefore `just check` in CI — validates every installed
skill: frontmatter present, `name` matching the installed directory, and a
`description` within the 1024-character Agent Skills limit.

### Adding a skill

- **Third-party**: add the repo as a `flake = false` input in `flake.nix`,
  forward it through `lib/skills.nix` as `externalSrcs.<name>`, add a source
  entry in `programs/skills/default.nix`, then add the skill name to
  `baseSkills` or a flavor's `extraSkills`.
- **Custom**: create `programs/skills/custom/<name>/SKILL.md`, add `<name>` to
  `custom`, then add it to `baseSkills` or a flavor's `extraSkills`.

## Neovim + LSP Architecture

**Neovim owns LSP client config. Project dev shells own LSP binaries.**

- `programs/nvim/languages/*.nix` — LSP client config only (`package = null` on all servers except `nil_ls`). No `extraPackages` for language tooling.
- `modules/home/languages/*.nix` — global LSP binaries and dev tools installed via Home Manager (e.g. `hls`, `fourmolu`, `typescript-language-server`).
- `nil_ls` is the only LSP with its binary baked into Neovim — Nix files have no project dev shell.

**direnv** (enabled in `modules/home/default.nix` via `programs.direnv.nix-direnv`) auto-activates a project's dev shell on `cd`. Project flakes only need a `.envrc` containing `use flake`. This puts project-pinned LSP binaries (e.g. GHC-matched HLS) on PATH, which Neovim's lspconfig picks up automatically.

Project flakes have **no dependency on this nixos repo** — they are standalone.

**Context-aware keymaps** (`programs/nvim/core/context-aware-keymaps.nix`) provide a single `<leader>tt` that dispatches to the right test runner at runtime. The registry (`_G.ContextRunners`) is initialized in `extraConfigLuaPre` (runs before all plugin/language Lua) to avoid ordering issues. Each language file registers its runner via `_G.RegisterContextRunner` in `extraConfigLua`.
