---
paths:
  - "programs/claude-code/default.nix"
  - "programs/claude-code/check.nix"
  - "programs/claude-code/config-check.nix"
  - "programs/claude-code/codegen/**"
  - "programs/claude-code/budget/**"
  - "programs/claude-code/statusline/**"
---

## Claude Code backend: flavors, codegen and budget

**Changing the Claude Code setup means editing `default.nix` and nothing else.**
The backend contract: `.claude/rules/agents-backend.md`. Installing:
`claude-code-install.md`; guards: `claude-code-hooks.md`.

- `default.nix` - the flavors, each its list of profiles plus Claude settings:
  `claude` and `claude-ts` get `base local`, `claude-web-ui`
  `base web-ui local`, `claude-all` `base web-ui pm local`, `claude-factory`
  `base factory`. The attr key
  is the binary name, so a flavor's name is written once.
- `codegen/` - pure, Claude's format: `settings.nix` (base settings,
  `withSecretFileGuard`), `profile.nix` (a folded profile as a flavor's files),
  `role.nix` (a role as `agents/<name>.md`), `mcp.nix` (`toWire`, no
  derivations, which is what makes it testable), `hooks.nix` (a profile's
  hooks as one settings entry per event, appended like `withSecretFileGuard`)
  and `tools.nix` (Claude's tools by vendor-free name: the one table a role's
  `tools:`, a hook matcher and the hook adapter read).
- `budget/` - the sizes only Claude's format adds, and `skillOverrides`.
- `statusline/` - the program the settings' status line points at.
- `check.nix` - `checks.claude-code`: the MCP wire shape, `withSecretFileGuard`
  and `applies.nix`. `config-check.nix` - `checks.claude-config`: the real
  configuration against its rules and ceilings.

### Budget and hidden skills

`budget/budget.json` holds ceilings on what Claude's format adds: each flavor's
model-invocable skill listing and each rendered subagent's frontmatter.
`just skill-budget` prints it with the agnostic table.

The factory's `skillOverrides` hides bundled and claude.ai-synced skills by
explicit name, `user-invocable-only` so `/name` still works, and
`disableClaudeAiConnectors` drops the Claude Docs connector. Both are measured
choices: none was used. `claude-code-remote` is not a connector, so `add_repo`
and `subscribe_pr_activity` stay. `checks.claude-config` fails if a catalog
skill lands on the hidden list.

### Subagents

`codegen/role.nix` renders each role as `~/.claude/agents/<name>.md`. A
spawned general-purpose agent starts at about 43k tokens, 18k of that MCP
schemas; a role far lower (reviewer 6.0k, implementer 13.3k, measured before
the last refactor), so flows spawn roles freely.

- Capabilities become a `tools:` allowlist, which also removes MCP and the
  Skill listing, and `omitClaudeMd` is set. Never add `ToolSearch` to a deny
  list: that inlines every deferred tool. Path-scoped `.claude/rules` still load
  on a Read.
- **Only `engineer` has the Skill tool** (the `skill` capability). Other roles
  get `skills:` preloads for what they always need, and `agent.md` says
  invoking a skill means reading its `SKILL.md`. A preload
  expands `${CLAUDE_SKILL_DIR}`, but `$ARGUMENTS` becomes empty: a preloaded
  skill must not depend on it.
- **A role has no root `CLAUDE.md`.** The brief names its checks, and
  `building.md` and the house-rules brief read the repo's file on demand.
- `checks.claude-config` holds the renders to known fields only, a `tools` list
  with no MCP, every preload in `base`, the factory section in the factory's
  render alone, and each role under its ceiling. A new documented field goes in
  its list and in `programs/agents/lib/role.nix`.
- `self-improve` names a role's loop step from its agent type, so a spawn site
  that names a role needs no matching brief.

### MCP wire format

`codegen/mcp.nix`'s `toWire` dispatches on the catalog's `type` through an
attrset (`mkLocal` is Claude's `stdio`, `mkRemote` its `http`), so an unhandled
transport aborts evaluation. A local server's `env` becomes `${VAR}` references
that Claude Code expands from the wrapper's environment.

### Secret file guard

Where a secret file's path is exported, `withSecretFileGuard` adds `Read` deny
rules over `/run/secrets` and `/run/secrets.d` and the `hooks/secret-guard`
Bash hook (`claude-code-hooks.md`).
