---
paths:
  - "programs/agents/**"
  - "programs/claude-code/**"
  - "programs/skills-link/**"
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

- `programs/agents/core.md` - what every agent gets, subagent roles included.
  `trivial.md` and `AGENTS.md` are for the agent leading a session, with
  `trivial.md` also in `review-lead`. Plain committed markdown, composed into
  `instructions`.
- `programs/agents/default.nix` - the shared surface: `instructions`, `skills`,
  `subagents` and `check`. `adapters/agents.nix` is its only adapter; it injects `flake = false`
  inputs as `externalSrcs`.
- `programs/claude-code/` - installs `instructions` as `~/.claude/CLAUDE.md`,
  the only user-scope memory file Claude Code reads, and renders the subagent
  records. It does **not** read
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

MCP transports, OAuth, the session runtime and secret files: `.claude/rules/claude-mcp.md`.

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

`~/.claude/skills` is **not** Home Manager managed. Each flavor wrapper relinks it
at launch from its own `linkFarm`, wiping it first (`claude-factory` swaps it
atomically, see below), so switching flavors never leaves a stale skill behind -
the same pattern `mkClaudeFlavor` already uses for `settings.json`, `CLAUDE.md`
and `.mcpServers`. **It is not hand-editable**: anything placed there is
destroyed on the next launch, so prototype in a project's `.claude/skills/`
instead.

The factory is the exception: its sessions never pass through a wrapper, so a
home activation relinks the farm too, under `~/.claude/.factory.lock`, and both
swap the directory atomically (`factory-link-skills`) instead of wiping it.

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
plus `budgetLoads` in `programs/claude-code/default.nix`: each subagent role's
factory render with what it preloads and reads, and this repo's root `CLAUDE.md`. Raising a
ceiling is allowed, and is the visible diff that makes the cost a decision. Keep
root `CLAUDE.md` small: detail belongs in a `.claude/rules/` file.

### Subagents

**`programs/agents/subagents/default.nix` holds one `mkAgent` record per role, and
nothing there names a harness. `programs/claude-code/agents.nix` renders them.
Adding a role is one record and its prose.**

A spawned general-purpose agent starts at about 43k tokens, 18k of that MCP
schemas no subagent uses. A role starts far lower, so flows spawn them freely.
Approximate first-call context, factory render, "reply ok" task, measured before
the last refactor and fixes: reviewer 6.0k, researcher 8.1k, fixer 11.2k,
review-lead 11.6k, implementer 13.3k.

- A record has `name`, `description`, `instructions` (prose paths; `core.md` goes
  in front), `capabilities` (`read edit shell web delegate`), `skills`, `tier` and
  `effort`. `record.nix` throws on anything unknown, and `checks.agents` proves
  it does: Claude Code ignores a misspelled field, and a misspelled `tools` would
  run the agent with every tool.
- The renderer turns capabilities into a `tools:` allowlist, which also removes
  MCP and the Skill listing, and sets `omitClaudeMd`. Never add `ToolSearch` to a
  deny list: that inlines every deferred tool. Path-scoped `.claude/rules` still
  load on a Read.
- **A role has no Skill tool.** `skills:` preloads what it always needs, and
  `core.md` says invoking a skill means reading its `SKILL.md`. A preload prints
  its base directory and expands `${CLAUDE_SKILL_DIR}`, but `$ARGUMENTS` becomes
  empty: a preloaded skill must not depend on it.
- **A role has no root `CLAUDE.md`.** The brief names its checks, and `build.md`
  and the house-rules brief read the repo's file on demand.
- A role gets `delegate` only if its flow spawns agents: `implementer` splits a
  large slice and `review-lead` spawns `reviewer`s. `fixer` and `reviewer` spawn
  nobody.
- `refactor`, the dry run, a fresh check, a delegated `engineer` and the `/qa`
  agents have no role yet and stay `general-purpose`, with the top-level
  instructions and the Skill tool. None needs MCP: add_repo, subscribe, CI waits
  and notifications stay top-level.
- The factory section is `programs/claude-code/factory-core.md`. Agent files are
  Home Manager: `home.file` installs `agentFiles` in the shared home profile and
  `factory.agentFiles`, the same records with that section, in the factory's.
  `factory-instructions.md` is what only its top-level sessions need.
- `~/.claude/agents` is a normal directory. Home Manager owns only the catalog's
  files, and leaves a hand-placed agent alone. A project's own
  `.claude/agents/<name>.md` silently beats the user-scope file in that repo.
- `checks.claude-config` holds the renders to this: known fields only, a `tools`
  list with no MCP, every preload in `baseSkills`, the factory section in the
  factory's render alone, and each role under its ceiling. A new documented field
  goes in its list and in `record.nix`.
- `self-improve` names a role's loop step from its agent type, so a spawn site
  that names a role needs no matching brief.

Trivial tasks spawn no researcher and skip the process skills, by the shared
definition in `programs/agents/trivial.md`. It keeps skill and instruction edits
out of Trivial unless they are typos, so a change here is never Trivial.

### Adding a skill

- **Third-party**: add the repo as a `flake = false` input in `flake.nix`,
  forward it through `adapters/agents.nix` as `externalSrcs.<name>`, add a source
  entry in `programs/agents/skills/default.nix`, then add the skill name to
  `baseSkills` or a flavor's `extraSkills`.
- **Custom**: create `programs/agents/skills/custom/<name>/SKILL.md`, add `<name>` to
  `custom`, then add it to `baseSkills` or a flavor's `extraSkills`.
