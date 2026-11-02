---
paths:
  - "programs/claude-code/**"
---

## Claude Code backend

**Changing the Claude Code setup means editing `default.nix` and nothing else.**
The backend contract: `.claude/rules/agents-backend.md`.

- `default.nix` - the flavors, each its list of profiles plus Claude settings:
  `claude` and `claude-ts` get `base`, `claude-web-ui` `base web-ui`,
  `claude-pm` `base web-ui pm`, `claude-factory` `base factory`. The attr key
  is the binary name, so a flavor's name is written once.
- `codegen/` - pure, Claude's format: `settings.nix` (base settings,
  `withSecretFileGuard`), `profile.nix` (a folded profile as a flavor's files),
  `role.nix` (a role as `agents/<name>.md`), `mcp.nix` (`toWire`, no
  derivations, which is what makes it testable).
- `link/` - effects that write `~/.claude`: `lib.nix` builds the flavor
  wrapper from the fragments listed in `link/fragments`, `link.sh` writes the
  files, `activation.nix` is what a rebuild writes.
- `load/` - `secrets.sh` (exports MCP secrets), `load.sh` (environment, exec)
  and `applies.nix` (`When` per written file).
- `hooks/<guard>/`, `hooks/shared/`, `statusline/` - the programs the settings
  point at.
- `budget/` - the sizes only Claude's format adds, and `skillOverrides`.
- `check.nix` - `checks.claude-code`: the MCP wire shape, `withSecretFileGuard`
  and `applies.nix`. `config-check.nix` - `checks.claude-config`: the real
  configuration against its rules and ceilings.

### The wrapper and `~/.claude`

The wrapper runs `secrets.sh` first: **a missing MCP secret aborts the launch
before anything in `~/.claude` is written.** Then it replaces
`settings.json`, `CLAUDE.md` (the lead's render, the only user-scope memory
file Claude Code reads; it ignores `AGENTS.md` there), the `mcpServers` key in
`~/.claude.json` and `~/.claude/skills`, and execs Claude Code. A project's own
`CLAUDE.md` still stacks on top.

`~/.claude/skills` is **not** Home Manager managed and **not hand-editable**:
each launch wipes and relinks it from the flavor's farm, so switching flavors
never leaves a stale skill. Prototype in a project's `.claude/skills/` instead.
The factory is the exception: its sessions never pass through a wrapper, so a
home activation relinks the farm too, under `~/.claude/.factory.lock`, and both
update the directory in place (`programs/skills-link`), one atomic rename per
link. Never replace the directory: deleting one empties it under a session that
has it open, and Claude Code keeps its own `synced/` there.

The factory's `skillOverrides` hides bundled and claude.ai-synced skills by
explicit name, `user-invocable-only` so `/name` still works, and
`disableClaudeAiConnectors` drops the Claude Docs connector. Both are measured
choices: none was used. `claude-code-remote` is not a connector, so `add_repo`
and `subscribe_pr_activity` stay. `checks.claude-config` fails if a catalog
skill lands on the hidden list.

`budget/budget.json` holds ceilings on what Claude's format adds: each flavor's
model-invocable skill listing and each rendered subagent's frontmatter.
`just skill-budget` prints it with the agnostic table.

### Subagents

`codegen/role.nix` renders each role as `~/.claude/agents/<name>.md`. A
spawned general-purpose agent starts at about 43k tokens, 18k of that MCP
schemas; a role far lower (reviewer 6.0k, implementer 13.3k, measured before
the last refactor), so flows spawn roles freely.

- Capabilities become a `tools:` allowlist, which also removes MCP and the
  Skill listing, and `omitClaudeMd` is set. Never add `ToolSearch` to a deny
  list: that inlines every deferred tool. Path-scoped `.claude/rules` still load
  on a Read.
- **A role has no Skill tool.** `skills:` preloads what it always needs, and
  `agent.md` says invoking a skill means reading its `SKILL.md`. A preload
  expands `${CLAUDE_SKILL_DIR}`, but `$ARGUMENTS` becomes empty: a preloaded
  skill must not depend on it.
- **A role has no root `CLAUDE.md`.** The brief names its checks, and
  `building.md` and the house-rules brief read the repo's file on demand.
- `home.file` installs `agentFiles` in the shared home profile and
  `factory.agentFiles`, with the factory profile's `agent.md`, in the
  factory's. Install shells copy the renders too.
- `~/.claude/agents` is a normal directory. The catalog's role names are
  Nix-owned: a file under one is replaced with no backup; any other name is
  left alone. A project's own `.claude/agents/<name>.md` beats it in that repo.
- `checks.claude-config` holds the renders to known fields only, a `tools` list
  with no MCP, every preload in `base`, the factory section in the factory's
  render alone, and each role under its ceiling. A new documented field goes in
  its list and in `programs/agents/lib/role.nix`.
- `self-improve` names a role's loop step from its agent type, so a spawn site
  that names a role needs no matching brief.

### MCP wire format and OAuth

`codegen/mcp.nix`'s `toWire` dispatches on the catalog's `type` through an
attrset (`mkLocal` is Claude's `stdio`, `mkRemote` its `http`), so an unhandled
transport aborts evaluation. A local server's `env` becomes `${VAR}` references
that Claude Code expands from the wrapper's environment.

A remote server's OAuth grant (`/mcp`, once per machine) lives in the macOS
Keychain (on Linux `~/.claude/.credentials.json`), keyed by the server's
`name`, `type`, `url` and `headers`. Nothing of it is in `~/.claude.json`, so
replacing `mcpServers` on every launch cannot lose it. Renaming a catalog entry
or changing its `url` orphans it (one re-login); logging out of the Claude
account wipes every grant
([claude-code#90647](https://github.com/anthropics/claude-code/issues/90647)).
A remote server cannot be host-gated: keeping one off a machine means not
running a flavor that lists it (`claude-pm` on `macos-main`).

### Secret files

The wrapper exports a secret file's **path**. Where one is exported,
`withSecretFileGuard` adds `Read` deny rules over `/run/secrets` and
`/run/secrets.d`, and the `hooks/secret-guard` Bash hook, which blocks a
command naming that directory or the file's basename, expanding the variable,
or running `printenv`/`env` inside a command substitution. **This is protection
against accidental reads, not a security boundary**: every `qa-node` script
must read the variable, so no filter over command text can close it.
`checks.qa` tests the wallet helper headless against a generated key;
`checks.python-tests` the guard.

The factory's Remote Control units run the unwrapped binary, so
`modules/home/factory/claude-factory.nix` installs `qa` too.
