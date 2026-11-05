---
paths:
  - "programs/claude-code/link/**"
  - "programs/claude-code/load/**"
  - "programs/skills-link/**"
  - "modules/home/claude*"
  - "modules/home/factory/claude-factory.nix"
---

## Claude Code backend: install and launch

The backend contract (`link` and `load` converge, idempotent):
`.claude/rules/agents-backend.md`.

- `link/` - effects that write `~/.claude`: `lib.nix` builds the flavor
  wrapper from the fragments listed in `link/fragments`, `link.sh` writes the
  files, `activation.nix` is what a rebuild writes.
- `load/` - `secrets.sh` (exports MCP secrets), `load.sh` (environment, exec)
  and `applies.nix` (`When` per written file).

### The wrapper and `~/.claude`

The wrapper runs `secrets.sh` first: **a missing MCP secret aborts the launch
before anything in `~/.claude` is written.** Then it replaces
`settings.json`, `CLAUDE.md` (the lead's render, the only user-scope memory
file Claude Code reads; it ignores `AGENTS.md` there), the `mcpServers` key in
`~/.claude.json` and `~/.claude/skills`, and execs Claude Code. A project's own
`CLAUDE.md` still stacks on top. It exports a secret file's **path**, never its
value.

`~/.claude/skills` is **not** Home Manager managed and **not hand-editable**:
each launch wipes and relinks it from the flavor's farm, so switching flavors
never leaves a stale skill. Prototype in a project's `.claude/skills/` instead.
The factory is the exception: its sessions never pass through a wrapper, so a
home activation relinks the farm too, under `~/.claude/.factory.lock`, and both
update the directory in place (`programs/skills-link`), one atomic rename per
link. Never replace the directory: deleting one empties it under a session that
has it open, and Claude Code keeps its own `synced/` there.

The factory's Remote Control units run the unwrapped binary, so
`modules/home/factory/claude-factory.nix` installs the factory profile's
`runtime` (`qa`, `ctx`) too.

### Subagent files

- `home.file` installs `agentFiles` in the shared home profile and
  `factory.agentFiles`, with the factory profile's `agent.md`, in the
  factory's. Install shells copy the renders too.
- `~/.claude/agents` is a normal directory. The catalog's role names are
  Nix-owned: a file under one is replaced with no backup; any other name is
  left alone. A project's own `.claude/agents/<name>.md` beats it in that repo.

### MCP OAuth

A remote server's OAuth grant (`/mcp`, once per machine) lives in the macOS
Keychain (on Linux `~/.claude/.credentials.json`), keyed by the server's
`name`, `type`, `url` and `headers`. Nothing of it is in `~/.claude.json`, so
replacing `mcpServers` on every launch cannot lose it. Renaming a catalog entry
or changing its `url` orphans it (one re-login); logging out of the Claude
account wipes every grant
([claude-code#90647](https://github.com/anthropics/claude-code/issues/90647)).
A remote server cannot be host-gated: keeping one off a machine means not
running a flavor that lists it (`claude-pm` on `macos-main`).
