---
paths:
  - "programs/agents/**"
  - "programs/claude-code/**"
  - "programs/farm-link/**"
  - "adapters/**"
  - "docs/adr/0002-*"
  - "modules/home/claude*"
  - "modules/home/factory/claude-factory.nix"
---

## Agent Configuration

**`programs/agents/` is agent-agnostic. Agent-specific code lives in that
agent's own program.**

`programs/agents/` provides content and knows nothing about installation,
because the agents disagree on where config goes. Each agent program installs
what it needs the way its tool expects. See
`docs/adr/0002-agent-agnostic-configuration.md`, which also documents how to add
a second agent such as Codex.

- `programs/agents/AGENTS.md` - the shared instructions, plain committed
  markdown. Exposed as `instructions`.
- `programs/agents/default.nix` - the shared surface: `instructions`, `skills`,
  `subagents` and `check`. `adapters/agents.nix` is its only adapter; it injects `flake = false`
  inputs as `externalSrcs`.
- `programs/claude-code/` - installs `instructions` as `~/.claude/CLAUDE.md`,
  the only user-scope memory file Claude Code reads. It does **not** read
  `AGENTS.md` at user scope. A project's own `CLAUDE.md` still stacks on top.

### Claude Code: config in `default.nix`, plumbing in `lib.nix`

**Changing the Claude Code setup means editing `default.nix` and nothing else.**

- `default.nix` - the configuration: `baseSettings`, `baseSkills`,
  `baseInstructions`, the `mcpCatalog`, and the flavors. Nothing derived lives
  here.
- `lib.nix` - `mkFlavorBuilder`, applied once to that configuration and
  returning the function from an attrset of flavors to their wrapper
  derivations. The attr key is the binary name, so a flavor's name is written
  once. Everything derived from the configuration - the available catalog, the
  list of defined server names, the merged settings - is computed once in that
  closure rather than per flavor.
- `mcp.nix` - the pure MCP logic: `mkStdioServer` and `mkHttpServer`,
  availability against this host's secrets, per-flavor selection, and the
  `~/.claude.json` structure. No derivations, which is what makes it testable.
- `check.nix` - `checks.claude-code`, running `mcp.nix` against a synthetic
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

- `programs/agents/skills/default.nix` - the catalog: third-party sources with an
  explicit allowlist and rename map, plus the list of enabled custom skills.
- `programs/agents/skills/lib.nix` - discovery, collision detection, rename, farm and
  validation. No policy.
- `programs/agents/skills/custom/<name>/SKILL.md` - hand-written skills, committed. A
  directory is only installed once its name is added to `custom`, so drafts can
  stay in version control. See `programs/agents/skills/custom/README.md`.

External sets are pinned as flake inputs rather than `fetchFromGitHub`. That is
deliberate: `modules/nix.nix` sets `allow-import-from-derivation = false`, so a
fetched derivation could not be `readDir`'d, but a flake input is a plain store
path and can be - which is what lets the allowlist use bare skill names that are
searched for recursively.

`~/.claude/skills` and `~/.claude/agents` are **not** Home Manager managed. Each
flavor wrapper relinks them at launch from `linkFarm`s, wiping them first
(`claude-factory` swaps them atomically, see below), so switching flavors never
leaves a stale entry behind - the same pattern `mkClaudeFlavor` already uses for
`settings.json`, `CLAUDE.md` and `.mcpServers`. Anything hand-placed there is
destroyed on the next launch; prototype in a project's `.claude/skills/` or
`.claude/agents/` instead.

The factory is the exception: its sessions never pass through a wrapper, so a
home activation relinks both farms too, under `~/.claude/.factory.lock`, and
both swap each directory atomically (`factory-link-farm`) instead of wiping it.

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

`nix flake check` - and therefore `just check` in CI - validates every installed
skill: frontmatter present, `name` matching the installed directory, and a
`description` within the 1024-character Agent Skills limit. It also runs
`checks.claude-code` over the MCP catalog logic.

The factory's `skillOverrides` hides bundled and claude.ai-synced skills from
the model by explicit name, `user-invocable-only` so `/name` still works, and
`disableClaudeAiConnectors` drops the Claude Docs connector. Both are measured
choices: none was used. `claude-code-remote` is not a connector, so `add_repo`
and `subscribe_pr_activity` stay. `checks.claude-config` fails if a catalog skill
lands on the hidden list.

### Size budget

**`programs/claude-code/budget.json` is a ceiling, in bytes, on what every agent
carries.** `checks.claude-config` fails above it; `just skill-budget` prints the
table. It counts each flavor's instructions and model-invocable skill listing,
plus `budgetLoads` in `programs/claude-code/default.nix`: what a review agent, an
implementer or a researcher reads, and this repo's root `CLAUDE.md`. Raising a
ceiling is allowed, and is the visible diff that makes the cost a decision. Keep
root `CLAUDE.md` small: detail belongs in a `.claude/rules/` file.

### Subagents

**`programs/agents/subagents/` owns the catalog, one `<name>.md` per agent type.
Every flavor installs all of it, the same way as skills, one farm for every
flavor.**

- `general-purpose.md` overrides the built-in, which nearly every spawn uses, to
  drop MCP with `disallowedTools: mcp__*`. Its body is the built-in's text. **It
  must never gain a `tools:` list**: that silently drops `Skill` and the skill
  listing. `checks.agents` fails if it does.
- `researcher.md` is read-only by its `tools:` allowlist, which has no Write,
  Edit, MCP or `Skill`. `omitClaudeMd: true` removes every CLAUDE.md, so its body
  restates the few house rules it needs. `skills: [researcher]` preloads the skill
  body: a preload needs no `Skill` tool. It sets no `model:`, so it runs on the
  session's model.
- A project's own `.claude/agents/<name>.md` beats the user-scope file, silently
  giving those savings back in that repo.
- `checks.agents` validates the frontmatter, rejects an unknown field, and
  requires each `skills:` entry to be in the skill catalog.

Trivial tasks spawn no researcher and skip the process skills, by the shared
definition in `programs/agents/AGENTS.md`. It keeps skill and instruction edits
out of Trivial unless they are typos, so a change here is never Trivial.

### Adding a skill

- **Third-party**: add the repo as a `flake = false` input in `flake.nix`,
  forward it through `adapters/agents.nix` as `externalSrcs.<name>`, add a source
  entry in `programs/agents/skills/default.nix`, then add the skill name to
  `baseSkills` or a flavor's `extraSkills`.
- **Custom**: create `programs/agents/skills/custom/<name>/SKILL.md`, add `<name>` to
  `custom`, then add it to `baseSkills` or a flavor's `extraSkills`.
