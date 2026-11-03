---
paths:
  - "programs/claude-code/**"
  - "programs/opencode/**"
  - "programs/codex/**"
  - "adapters/claude-code.nix"
---

## Agent backends

**A backend only translates the frontend's output into its vendor's format and
installs it. Catalogs, selection, secret gating, validation, ordering, dedup
and the agnostic budget live in `programs/agents`
(`.claude/rules/agents-frontend.md`).** Why: `docs/adr/0011-agent-compiler.md`.
Claude Code is the only backend today.

A backend is `programs/<vendor>/`, imported only by `adapters/<vendor>.nix`:

| Part | Pure | Owns | Must not |
|---|---|---|---|
| `default.nix` | yes | the flavors: each its list of profiles plus vendor settings | hold agent content |
| `codegen/` | yes | the vendor's format, fields it cannot honour | touch `$HOME`, hold catalogs |
| `budget/` | yes | sizes only the vendor's format adds | repeat the agnostic budget |
| `link/` | no | the paths it writes in `$HOME` | branch on prior state or run order |
| `load/` | no | launch, reload, restart; when each file applies | rewrite config |

- A flavor folds its profiles with `agents.fold`, which already ran the dedup
  guard and narrowed MCP servers and secret files to this host's `secrets`.
- **Honest backend.** A field the vendor cannot honour throws, or degrades in a
  documented way; never dropped silently (a dropped tool list widens a role).
- **One owner per target.** Two store paths for one target path must be an eval
  error, never last-writer-wins.
- **Parse before the first effect.** Everything that can fail (a missing MCP
  secret) fails before `link` writes anything.
- `link` and `load` follow `.claude/rules/reproducibility.md`: converge on what
  Nix owns, leave the rest untouched, idempotent.
- `When` is `Live | NextSession | Restart`: when a changed file reaches a
  running session.
- Adding a backend changes nothing in `programs/agents`: see
  `docs/adr/0002-agent-agnostic-configuration.md`, "Adding a new agent".
