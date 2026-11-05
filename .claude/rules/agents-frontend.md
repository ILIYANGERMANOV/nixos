---
paths:
  - "programs/agents/**"
  - "adapters/agents.nix"
---

## Agents frontend

**`programs/agents/` is the source language and the frontend of the agent
compiler. It names no vendor, no host and no `$HOME` path, and installs
nothing.** Why, and how a backend consumes it: `docs/adr/0011-agent-compiler.md`.

Prefer a deterministic program over an agent instruction, unless it limits the
agent or forces a chain of commands: `docs/adr/0013-deterministic-programs-over-instructions.md`.

Nothing in `programs/agents` may reach `programs/claude-code`, `opencode` or
`codex`, even through another program (Deslop `agents-name-no-vendor`).
`adapters/agents.nix` is its only adapter: it injects `flake = false` inputs as
`externalSrcs`, `playwright`'s `qa` and the host's `secrets`.

### Source

Each folder has its own rule, loaded when you work in it:

| Folder | Holds | Rule |
|---|---|---|
| `instructions/`, `lib/` | prose every agent gets; the laws | `agents-lib.md` |
| `profiles/<name>/` | one vendor-free setup | `agents-profiles.md` |
| `roles/<name>/` | one subagent role | `agents-roles.md` |
| `skills/` | the skill catalog | `agents-skills.md` |
| `mcp/` | the MCP catalog | `agents-mcp.md` |

`default.nix` is the surface: `profiles`, `fold`, `renderLead`, `renderRole`,
`skills`, `ctx`, `roles`, `budget` and `check`. `checks.agents` proves every law and
every rejection.

### Laws

**Every combinator is a monoid that throws on a conflict, never
last-writer-wins.** A misspelled field, an unknown name or one key with two
values is an eval error, because a backend's format may ignore it and a
dropped field can widen what an agent may do. Detail: `agents-lib.md`.

### The ladder

**A role reads only its own folder and any `shared/` at or above it, never
another role** (Deslop `roles-climb-the-ladder`). Prose moves to `shared/` at
its second reader, never in anticipation, and back out when one is left.

### Size budget

**`budget.json` holds ceilings, in bytes, on what every agent carries**, named
by no vendor: each flavor's instructions, each role's instructions with what it
preloads and reads, and this repo's root `CLAUDE.md`. `checks.claude-config`
fails above them; `just skill-budget` prints the table. Raising a ceiling is
allowed, and is the visible diff that makes the cost a decision. Keep root
`CLAUDE.md` small: detail belongs in a `.claude/rules/` file.
