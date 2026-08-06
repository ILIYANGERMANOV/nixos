# Agent-agnostic configuration provides content, never installation

Coding agents are converging on the same ideas - a user-scope instructions file,
a directory of skills - and diverging on every detail of where those live. This
repo therefore splits the two: `programs/agents/` owns config that is true
regardless of which agent reads it, and each agent's own program owns the
knowledge of how that agent wants it on disk.

Four words, used precisely throughout:

- **Agent** - a coding CLI: Claude Code, Codex. Claude Code is the only one
  installed today.
- **Flavor** - a named wrapper binary around one agent with a fixed
  settings/MCP/skills profile (`claude`, `claude-ts`, `claude-web-ui`). A
  Claude-specific concept; nothing in `programs/agents/` knows the word.
- **Instructions** - the agent-agnostic prose in `programs/agents/AGENTS.md`,
  loaded at user scope so it applies in every repository.
- **Skill** - a `SKILL.md` directory. Agent-agnostic because the format is
  shared, even though Claude Code is currently its only consumer.

## Why the shared layer does not install anything

`programs/agents/default.nix` exports `instructions = ./AGENTS.md` and stops
there. The obvious alternative - having it write `~/.claude/CLAUDE.md` and
`~/.codex/AGENTS.md` itself - fails on the first agent, because Claude Code does
not read `AGENTS.md` at user scope at all. Its memory loader only ever resolves
`CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md` and `.claude/rules/`; every
`AGENTS.md` reference in the shipped binary belongs to the `/import`-from-Codex
codepath, which reads a Codex `AGENTS.md` and writes it out as `CLAUDE.md`.

So there is no filename that is simultaneously correct for both agents. A shared
layer that picked one would be agent-shaped while claiming not to be, and the
second agent would arrive as a special case in code that was supposed to be
neutral. Giving each agent program the whole installation decision costs a few
lines per agent and keeps the shared layer honestly shared.

The same reasoning explains why `programs/claude-code/` did not move under
`programs/agents/`. `programs/agents/` is not a namespace for everything
agent-related; it is the set of things that are *not* specific to an agent.

## Why user memory is Nix-owned and clobbered

The flavor wrapper rewrites `~/.claude/CLAUDE.md` from the store on every launch,
exactly as it already does for `settings.json`, `.mcpServers` and
`~/.claude/skills`. The setup is immutable by design: what the flake says is what
is on disk, and switching flavors can never leave a stale rule behind.

The cost is Claude Code's `#` memory shortcut, which writes to that exact file
and whose writes therefore vanish on the next launch. Accepted: `autoMemoryEnabled`
is already `false`, and per-repository rules belong in a project's own
`CLAUDE.md`, which still applies. User and project memory are separate entries in
Claude Code's loader, so a store-owned user file does not displace anything a
repository says.

Flavors can append their own prose through `extraInstructions`, concatenated onto
`baseInstructions`. It is empty for all three flavors today and should stay that
way unless a rule is genuinely Claude-only - anything in there is a rule Codex
will never see.

## Why `install -m 600` and not `cp`

Store paths are mode 444. `cp` opens its destination for writing, so copying a
store path over a previous copy of itself fails with `EACCES` - fatal in a
wrapper running under `set -o errexit`.

The pre-existing `cp` of `settings.json` survived only by accident: Claude Code
rewrites that file itself with mode 600, so the wrapper never met its own output.
`CLAUDE.md` is never rewritten by Claude Code, so the bug would have fired on the
second launch. Both copies now use `install -m 600`, which sets the mode on the
destination it writes and is therefore repeatable.

## Adding a new agent

Nothing in `programs/agents/` changes. Using Codex as the worked example:

1. Add the package. `llm-agents.nix` is already an input and exposes `codex`.
2. Create `programs/codex/default.nix`, a plain function taking `pkgs` and
   `agents`, returning a wrapper that installs what Codex expects and execs it:

   ```nix
   pkgs.writeShellApplication {
     name = "codex";
     text = ''
       mkdir -p "$HOME/.codex"
       install -m 600 ${agents.instructions} "$HOME/.codex/AGENTS.md"
       exec ${codex}/bin/codex "$@"
     '';
   }
   ```

3. Create `lib/codex.nix` mirroring `lib/claude-code.nix`: import
   `programs/codex` and pass it `agents = import "${root}/lib/agents.nix" { ... }`.
4. Create `modules/home/codex.nix` wiring the packages and any activation script
   into Home Manager, and register it in `modules/home/default.nix`.

Skills would follow the same route when wanted: Codex declares them as
`[[skills]]` entries in `~/.codex/config.toml` rather than a directory of
symlinks, so `programs/codex/` would consume `agents.skills.mkSkillFarm` and
render its own TOML. That difference is exactly the kind of thing the shared
layer is kept free of.

## Consequences

- **`~/.claude/CLAUDE.md` is not editable.** Hand-edits and `#` memory writes are
  discarded at the next launch. The file to edit is
  `programs/agents/AGENTS.md`, followed by a rebuild.
- **The instructions are not enforced.** They tell an agent what to write; no
  check verifies the result, and the existing repository was deliberately not
  swept to match. Mixed punctuation in older files is expected and is not a
  defect.
- **`checks.skills` is now `checks.agents`**, sourced from `lib/agents.nix`, and
  is the place any future build-time validation of shared agent config belongs.
- **One adapter, one entry point.** `lib/agents.nix` replaced `lib/skills.nix`
  as the sole injector of `flake = false` skill inputs, so a second agent wires
  up one import rather than two.
