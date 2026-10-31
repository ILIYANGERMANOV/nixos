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
programs/agents/— agent-agnostic config shared by every coding agent (AGENTS.md, skill catalog)
shells/         — dev shells (default for repo recipes, nixos-install, darwin-install)
secrets/        — sops-encrypted: common.yaml (global) + hosts/<hostname>.yaml
deslop/         - the architecture rules `deslop check .` enforces, and their baseline
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

1. A skill or instruction `.md` edit: `nix build --no-link .#checks.x86_64-linux.agents`
   and `.#checks.x86_64-linux.typos`, plus `self-improve` when the analyzer under
   its skill changed.
2. A `programs/<x>` edit: build that program's check - `claude-code` and
   `claude-bash-guards` for `programs/claude-code`, `nvim-search`,
   `nvim-typescript` and `nvim-kotlin` for `programs/nvim`, `nvim-kotlin` plus
   a `software-factory` host eval for `programs/kotlin`, `software-factory`,
   `playwright` and `qa` (Linux only) for `programs/playwright`, `typos` - as `nix build --no-link .#checks.x86_64-linux.<name>`.
3. A `modules/` or `hosts/` edit: evaluate the touched host only, with
   `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
   (`lenovo-old`, `software-factory`) or
   `nix eval --raw .#darwinConfigurations.<host>.system.drvPath` (`macos-main`, `macos-work`).
   An added, moved or re-pointed import: `nix develop -c just architecture`
   (Deslop, under a second).
4. A `.github/` edit: `nix build --no-link .#checks.x86_64-linux.zizmor`.
5. `just quick-check` before handing back mid-work: lint, architecture, format and every
   `checks` derivation for this system. On Linux that evaluates one host, for
   `software-factory-activation`, and no other.
6. `just check` once on the final state, run as the Checks rules in
   `programs/agents/AGENTS.md` say. Never after a docs-only edit, and never
   with a build, lint or test chained in front of it.

## Dependency Updates

**`nixpkgs` tracks `nixpkgs-26.05-darwin`, not `nixos-26.05`. That is deliberate - do not "fix" it.**

Both branches fast-forward along `release-26.05`, but different Hydra jobsets advance them, so they land on different revisions. A rev from `nixos-26.05` is guaranteed to have *Linux* binaries in `cache.nixos.org`; darwin coverage is incidental. One such rev cost hours of Swift and .NET compilation and had to be reverted (`987b09a` → `58f2f8e`). See `docs/adr/0004-darwin-tracks-the-darwin-channel.md`; `lenovo-old`'s side of that trade is tracked in `docs/NON-DARWIN-NIXOS-ISSUES.md`.

`just darwin-cache-check` dry-runs the `macos-main` closure and fails if anything in `just/nix-darwin/expensive-builds.deny` would be built locally. Run it before pulling a dependency bump; CI runs it on every PR in the `cache-guard` job. It runs on Linux because `--dry-run` only queries substituters and never needs a darwin builder, but the substituter list in the workflow must stay in sync with `modules/nix.nix`, or it reports false misses.

The denylist is a plain pattern-per-line file, edited by hand. Anchor every pattern with `^`: unanchored, `go-1\.` also matches car`go-1.9`6.1-aarch64-apple-darwin, which herdr's rust-overlay toolchain builds every time. The recipe self-tests its own pipeline against a synthetic plan before trusting a real one, because both of its failure modes report a bad plan as clean.

Dependabot splits nix inputs into `nixpkgs-core` (guard-gated), `ai` (agent tooling and skill sources) and `ungrouped` (a catch-all matching everything else), so a nixpkgs rev the guard rejects does not also hold back herdr, llm-agents and the skills, and an input nobody classified still gets updates instead of silently freezing. `ungrouped` restates the other two memberships in `exclude-patterns` because dependabot has no group-reference syntax; keep them in step.

## Secrets

**`myConfig.secrets` is the only door to `sops.secrets`. Never write
`sops.secrets` by hand.**

Every secret has a **scope**, which picks the file it is read from:
`global` -> `secrets/common.yaml` (every host), `host` -> `secrets/hosts/<hostname>.yaml`
(only hosts that declare it). Names are bare: `figma-token`, never
`figma-token-macos-work`. The file already says which host it belongs to.

`modules/secrets.nix` holds the registry, the age key path and the expansion
into `sops.secrets`. A host declares what it provides in one line
(`myConfig.secrets.figma-token = { };`) and says nothing at all about secrets it
does not have. `scope` is explicit rather than inferred because the module
system merges all definitions and erases where each came from.

**A declaration is a promise, and absence is a feature.** Declaring a secret
asserts the value exists in the matching file; a missing file is a build error.
Not declaring one is how a host opts out, so anything depending on a secret must
key off its availability and disable itself where it is absent - never assume
every host has every secret, and never add a placeholder value to make a build
pass. That placeholder is exactly what this design removed.

Home Manager receives `secretsConfig` (`name -> path`, declared secrets only)
through `extraSpecialArgs`, alongside `userConfig` and `themeConfig`.
`programs/` takes it as a plain parameter and stays host-agnostic: it gates on
what it was handed, it never looks a host up. `programs/claude-code` is the
worked example - catalog entries name the secrets they need
(`env.FIGMA_API_KEY = "figma-token"`), unavailable entries are dropped before
any flavor sees them, and names are validated against the full catalog so a typo
still aborts while an unavailable server stays silent.

**Paths only, never values.** `sops.secrets.<n>.path` is a build-time string and
producing it decrypts nothing. `builtins.readFile` on a decrypted path would
bake plaintext into a world-readable store path: do not do it. Secrets are read
at runtime by the process that needs them.

All hosts share one age key today, so the per-host split is organisational, not
a trust boundary. See `docs/adr/0005-host-scoped-secrets.md` for the upgrade
path, and `docs/SOPS.md` for the day-to-day recipes.

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
  and `check`. `adapters/agents.nix` is its only adapter; it injects `flake = false`
  inputs as `externalSrcs`.
- `programs/claude-code/` — installs `instructions` as `~/.claude/CLAUDE.md`,
  the only user-scope memory file Claude Code reads. It does **not** read
  `AGENTS.md` at user scope. A project's own `CLAUDE.md` still stacks on top.

### Claude Code: config in `default.nix`, plumbing in `lib.nix`

**Changing the Claude Code setup means editing `default.nix` and nothing else.**

- `default.nix` — the configuration: `baseSettings`, `baseSkills`,
  `baseInstructions`, the `mcpCatalog`, and the flavors. Nothing derived lives
  here.
- `lib.nix` — `mkFlavorBuilder`, applied once to that configuration and
  returning the function from an attrset of flavors to their wrapper
  derivations. The attr key is the binary name, so a flavor's name is written
  once. Everything derived from the configuration — the available catalog, the
  list of defined server names, the merged settings — is computed once in that
  closure rather than per flavor.
- `mcp.nix` - the pure MCP logic: `mkStdioServer` and `mkHttpServer`,
  availability against this host's secrets, per-flavor selection, and the
  `~/.claude.json` structure. No derivations, which is what makes it testable.
- `check.nix` — `checks.claude-code`, running `mcp.nix` against a synthetic
  catalog and a synthetic `secrets` attrset.

#### Two transports, two auth stories

A catalog entry is a **local** server or a **remote** one, tagged by `type`. The
tag is the same field Claude Code reads from `~/.claude.json`, so writing an
entry out is a projection rather than a translation, and `toWire` dispatches on
it through an attrset - an unhandled transport aborts evaluation instead of
falling through to a wrong shape.

**Local (`mkStdioServer`)** - Claude Code spawns a subprocess. Its `env` maps an
environment variable to the **name** of the secret that fills it. Omitting `env`
means the server needs no secrets - an empty attrset, not a special case, so
availability is simply "every secret this server names is declared" and holds
vacuously for none. This is the only mechanism that gates a server to a host.

**Remote (`mkHttpServer`)** - Claude Code connects over HTTP and authenticates
**out-of-band**: `/mcp` inside a running session opens the OAuth flow, once per
machine. There is no secret to inject, so a remote server carries `env = { }`
and is available on every host. **A remote server cannot be host-gated by the
secrets mechanism.** Keeping one off a machine means not running a flavor that
lists it - which is why `claude-pm` exists on `macos-main` but is simply not
used there.

The OAuth grant lives in the **macOS Keychain** (on Linux,
`~/.claude/.credentials.json`) under a key derived from the server's `name`,
`type`, `url` and `headers`. Nothing about it is in `~/.claude.json`, which is
why the wrapper replacing `.mcpServers` wholesale on every launch cannot lose
it, and why switching flavors never forces a re-login. Two things do orphan a
grant: **renaming a catalog entry or changing its `url`** (one re-login), and
logging out of the Claude account, which wipes every MCP grant at once
([claude-code#90647](https://github.com/anthropics/claude-code/issues/90647)).

`mkHttpServer` takes only a `url`. Claude Code expands `${VAR}` references in
`headers` exactly as it does in `env` on a local server, so a remote server
that ever wants a static bearer token - both Linear and Superhuman Docs accept
one - is a small addition here rather than a redesign. Nothing needs it yet,
and a static token is what would let a remote server be host-gated after all.

#### Session runtime and secret files

`runtime` in `default.nix` is put on PATH by every flavor wrapper: today
`programs/playwright`'s `qa` - `qa-node` (Node resolving `playwright` with
nixpkgs' Chromium, `viem` and the `qa-wallet` helper from any directory) and
`qa-mp4` (ffmpeg). The environment lives inside `qa-node`, never the session,
so a project's own Playwright keeps its own browsers. The factory's Remote
Control units run the unwrapped binary, so its profile installs `qa` too.

`secretFiles` maps an env var to a secret **name**, for a program that reads
the file itself: the wrapper exports the decrypted file's **path**, never its
value (`QA_EVM_KEY_FILE` -> `qa-sepolia-key`, declared on `macos-work` only).
A host without the secret gets no variable. Where one is exported,
`withSecretFileGuard` in `lib.nix` adds `Read` deny rules over the secrets
directory (`/run/secrets` and the `/run/secrets.d` it resolves to) and the
`claude-secret-guard` Bash hook, which blocks a command naming that directory
or the file's basename, expanding the variable, or running `printenv`/`env`
inside a command substitution. **This is protection against accidental reads,
not a security boundary**: every `qa-node` script must read the variable, so a
script (or a determined session) can read the file, and no filter over command
text can close that. `checks.qa` tests the wallet helper and the video
pipeline headless against a generated key; `checks.claude-bash-guards` the
guard.

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

`~/.claude/skills` is **not** Home Manager managed. Each flavor wrapper relinks it
at launch from its own `linkFarm`, wiping it first (`claude-factory` swaps it
atomically, see below), so switching flavors never leaves a
stale skill behind — the same pattern `mkClaudeFlavor` already uses for
`settings.json`, `CLAUDE.md` and `.mcpServers`. Anything hand-placed there is
destroyed on the next launch; prototype in a project's `.claude/skills/` instead.

The factory is the exception: its sessions never pass through a wrapper, so a
home activation relinks the farm too, under `~/.claude/.factory.lock`, and
both swap the directory atomically (`factory-link-skills`) instead of wiping it.

Skills are assigned with `baseSkills` (shared by every flavor, declared in
`programs/claude-code/default.nix`) plus per-flavor `extraSkills`. Every flavor
gets every shared skill, `ui-coding` included, because a model-invoked skill
costs only its description until a task needs it. There are two exceptions.
`self-improve` is in the `extraSkills` of `claude-factory` and `claude-pm` only:
it measures the machine's own transcripts, and on the Macs it relies on the
`python3` (3.10+) that `modules/home/terminal.nix` installs. Its analyzer
(`scripts/analyze.py`) is tested by `checks.self-improve` against synthetic
transcripts, never real ones, because this repository is public.
`10x-engineer` is in the `extraSkills` of `claude-factory` only: it runs
delegated `engineer` subagents and leans on the factory's PR wakes and
notifications. It invokes `engineer` with the Skill tool, so `engineer` must
never set `disable-model-invocation`.
Instructions work the same way: `baseInstructions` plus per-flavor
`extraInstructions`, which only `claude-factory` uses.

`nix flake check` — and therefore `just check` in CI — validates every installed
skill: frontmatter present, `name` matching the installed directory, and a
`description` within the 1024-character Agent Skills limit. It also runs
`checks.claude-code` over the MCP catalog logic.

### Adding a skill

- **Third-party**: add the repo as a `flake = false` input in `flake.nix`,
  forward it through `adapters/agents.nix` as `externalSrcs.<name>`, add a source
  entry in `programs/agents/skills/default.nix`, then add the skill name to
  `baseSkills` or a flavor's `extraSkills`.
- **Custom**: create `programs/agents/skills/custom/<name>/SKILL.md`, add `<name>` to
  `custom`, then add it to `baseSkills` or a flavor's `extraSkills`.

## Software factory

**`software-factory` is a headless server whose agents are driven from a phone
via Claude Code Remote Control. Its configuration must never change another
host.** See `docs/adr/0007-software-factory.md` (design, trust boundaries,
accepted risks) and `docs/SOFTWARE-FACTORY.md` (runbook).

- `lib.mkNixosServer` imports `modules/nixos/server/` and no desktop module;
  nothing else imports that directory. The agent account's Home Manager profile
  is `modules/home/factory/`, its own import list - `modules/home/default.nix`
  is untouched by it.
- `programs/software-factory/` holds the logic: managed settings (billing and
  permission policy), the Remote Control launchers, `factory-ctl` (`ctl/`), the
  root deploy and maintenance scripts (`ops/`), the admin agent's project
  (`admin/`) and the egress nftables rules. `checks.software-factory`
  (`check.nix`, scenarios in `check.sh`) tests them.
  `checks.software-factory-activation` reads the relink hook off the host's Home
  Manager config, a lazy partial eval.
- **The admin agent runs the box; `factory-ctl` is its only tool.** Add an
  admin capability as a `factory-ctl` command with a scenario in `check.sh`,
  then a skill in `admin/skills/` that calls it. Skills there are
  project-scoped to `~/admin` on purpose - never add them to the shared skill
  catalog, which every agent of the account loads.
- **Deploys are pulled, never pushed.** `factory-deploy` (`modules/nixos/server/ops.nix`)
  polls this repository's GitHub deployments, verifies the commit is the tip
  of `main`, and switches behind a health gate. Root units it adds must set
  `restartIfChanged = false`, and Remote Control units keep
  `X-SwitchMethod = keep-old`, or a deploy kills its own caller.
- **The Android toolchain is global, never per repository.** `programs/kotlin`
  holds it: `workstation` (JDK 17, kotlin-lsp, ktlint, adb) for every host,
  `android` (store SDK, Gradle memory settings, konan's nix-ld libraries) for
  the factory only, wired by `modules/home/factory/android.nix`, the Remote
  Control units' environment and `nix-ld.nix`. The SDK licence is accepted
  there, not in nixpkgs' config. A missing SDK component is added to that SDK.
- The `claude-factory` flavor is `factory` in `programs/claude-code`, deliberately
  outside `packages` so no other host installs it.
- The server has its own sops age key; `secrets/common.yaml` is not encrypted
  to it.
- **This repository is public.** Never commit IP addresses, tailnet names,
  private repository names or anything that maps the server's attack surface
  beyond what the Nix config itself states. Private repositories are added on
  the box with `factory-ctl start` (the admin agent's `/start-repo`).
- Recipes are in `just/software-factory.just`.

## Neovim

Neovim, LSP and picker rules live in `programs/nvim/CLAUDE.md`. It loads for work
under `programs/nvim`; read it before editing `modules/home/languages/`.
