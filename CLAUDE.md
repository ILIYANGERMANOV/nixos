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
programs/agents/— agent-agnostic config shared by every coding agent (AGENTS.md, skill catalog)
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

## Dependency Updates

**`nixpkgs` tracks `nixpkgs-26.05-darwin`, not `nixos-26.05`. That is deliberate - do not "fix" it.**

Both branches fast-forward along `release-26.05`, but different Hydra jobsets advance them, so they land on different revisions. A rev from `nixos-26.05` is guaranteed to have *Linux* binaries in `cache.nixos.org`; darwin coverage is incidental. One such rev cost hours of Swift and .NET compilation and had to be reverted (`987b09a` → `58f2f8e`). See `docs/adr/0004-darwin-tracks-the-darwin-channel.md`; `lenovo-old`'s side of that trade is tracked in `docs/NON-DARWIN-NIXOS-ISSUES.md`.

`just darwin-cache-check` dry-runs the `macos-main` closure and fails if anything in `just/nix-darwin/expensive-builds.deny` would be built locally. Run it before pulling a dependency bump; CI runs it on every PR in the `cache-guard` job. It runs on Linux because `--dry-run` only queries substituters and never needs a darwin builder, but the substituter list in the workflow must stay in sync with `modules/nix.nix`, or it reports false misses.

The denylist is a plain pattern-per-line file, edited by hand. Anchor every pattern with `^`: unanchored, `go-1\.` also matches car`go-1.9`6.1-aarch64-apple-darwin, which herdr's rust-overlay toolchain builds every time. The recipe self-tests its own pipeline against a synthetic plan before trusting a real one, because both of its failure modes report a bad plan as clean.

Dependabot splits nix inputs into `nixpkgs-core` and `tools` so a nixpkgs rev the guard rejects does not also hold back herdr, llm-agents and the skills.

## Agent Configuration

**`programs/agents/` is agent-agnostic. Agent-specific code lives in that
agent's own program.**

`programs/agents/` provides content and knows nothing about installation,
because the agents disagree on where config goes. Each agent program installs
what it needs the way its tool expects. See
`docs/adr/0002-agent-agnostic-configuration.md`, which also documents how to add
a second agent such as Codex.

- `programs/agents/AGENTS.md` — the shared instructions, plain committed
  markdown. Exposed as `instructions`.
- `programs/agents/default.nix` — the shared surface: `instructions`, `skills`
  and `check`. `lib/agents.nix` is the only adapter; it injects `flake = false`
  inputs as `externalSrcs`.
- `programs/claude-code/` — installs `instructions` as `~/.claude/CLAUDE.md`,
  the only user-scope memory file Claude Code reads. It does **not** read
  `AGENTS.md` at user scope. A project's own `CLAUDE.md` still stacks on top.

### Agent Skills

**`programs/agents/skills/` owns the catalog. The Claude flavor wrappers own the disk.**

- `programs/agents/skills/default.nix` — the catalog: third-party sources with an
  explicit allowlist and rename map, plus the list of enabled custom skills.
- `programs/agents/skills/lib.nix` — discovery, collision detection, rename, farm and
  validation. No policy.
- `programs/agents/skills/custom/<name>/SKILL.md` — hand-written skills, committed. A
  directory is only installed once its name is added to `custom`, so drafts can
  stay in version control. See `programs/agents/skills/custom/README.md`.

External sets are pinned as flake inputs rather than `fetchFromGitHub`. That is
deliberate: `modules/nix.nix` sets `allow-import-from-derivation = false`, so a
fetched derivation could not be `readDir`'d, but a flake input is a plain store
path and can be — which is what lets the allowlist use bare skill names that are
searched for recursively.

`~/.claude/skills` is **not** Home Manager managed. Each flavor wrapper wipes and
relinks it at launch from its own `linkFarm`, so switching flavors never leaves a
stale skill behind — the same pattern `mkClaudeFlavor` already uses for
`settings.json`, `CLAUDE.md` and `.mcpServers`. Anything hand-placed there is
destroyed on the next launch; prototype in a project's `.claude/skills/` instead.

Skills are assigned with `baseSkills` (shared by every flavor, declared in
`programs/claude-code/default.nix`) plus per-flavor `extraSkills`. Instructions
work the same way: `baseInstructions` plus per-flavor `extraInstructions`, which
is empty everywhere today.

`nix flake check` — and therefore `just check` in CI — validates every installed
skill: frontmatter present, `name` matching the installed directory, and a
`description` within the 1024-character Agent Skills limit.

### Adding a skill

- **Third-party**: add the repo as a `flake = false` input in `flake.nix`,
  forward it through `lib/agents.nix` as `externalSrcs.<name>`, add a source
  entry in `programs/agents/skills/default.nix`, then add the skill name to
  `baseSkills` or a flavor's `extraSkills`.
- **Custom**: create `programs/agents/skills/custom/<name>/SKILL.md`, add `<name>` to
  `custom`, then add it to `baseSkills` or a flavor's `extraSkills`.

## Neovim + LSP Architecture

**Neovim owns LSP client config. Project dev shells own LSP binaries.**

- `programs/nvim/languages/*.nix` — LSP client config only (`package = null` on all servers except `nil_ls`). No `extraPackages` for language tooling.
- `modules/home/languages/*.nix` — global LSP binaries and dev tools installed via Home Manager (e.g. `hls`, `fourmolu`, `typescript-language-server`).
- `nil_ls` is the only LSP with its binary baked into Neovim — Nix files have no project dev shell.

**direnv** (enabled in `modules/home/default.nix` via `programs.direnv.nix-direnv`) auto-activates a project's dev shell on `cd`. Project flakes only need a `.envrc` containing `use flake`. This puts project-pinned LSP binaries (e.g. GHC-matched HLS) on PATH, which Neovim's lspconfig picks up automatically.

Project flakes have **no dependency on this nixos repo** — they are standalone.

**Context-aware keymaps** (`programs/nvim/core/context-aware-keymaps.nix`) provide a single `<leader>tt` that dispatches to the right test runner at runtime. The registry (`_G.ContextRunners`) is initialized in `extraConfigLuaPre` (runs before all plugin/language Lua) to avoid ordering issues. Each language file registers its runner via `_G.RegisterContextRunner` in `extraConfigLua`.

## Neovim Search

**fff owns `<leader>ff`. Telescope owns every other picker.** Two engines by
design, not a half-finished migration - see
`docs/adr/0003-fff-owns-file-search.md`.

`programs/nvim/core/search/` splits along that boundary:

- `file.nix` - fff plus the telescope file pickers (`<leader>fa`, `fe`, `fr`).
- `grep.nix` - content search (`<leader>fw`, `fg`, `fd`, `ss`).
- `default.nix` - telescope engine config belonging to neither (`ui-select`,
  `fzf-native`, `file_ignore_patterns`), plus `<leader>fl` and `<leader>nh`.
- `shared.nix` - a plain function, **not** a module, so it can export helpers.
  Holds the single `excludeDirs` list that both the `fd --exclude` flags and
  telescope's `file_ignore_patterns` are derived from. Add an exclusion here,
  never in one consumer.

Anything needing `vim.ui.select` (code actions), quickfix population from a text
search, or git-ignored files must stay on telescope: fff provides no
`vim.ui.select` and has no "show git-ignored" mode.

The nixvim `fff` module is **freeform** - no `settingsOptions`, so a misspelled
key is silently ignored instead of failing the build, and its `settingsExample`
is stale against the pinned version. `plugins.fff.settings` is therefore kept
minimal; everything not set there is relied on as a fff default. Verify any
change to it by running the built Neovim, not by trusting evaluation.
