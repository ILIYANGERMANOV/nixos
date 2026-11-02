# Agent config is a compiler: one vendor-free frontend, thin vendor backends

Adding a role, skill, tool or MCP server should touch one place, and adding a
vendor (OpenCode, Codex) should not copy any of that logic. So the agent config
is built like a compiler: `programs/agents` is the source language and the
frontend, and each `programs/<vendor>` is a backend that only translates and
installs. This refines ADR 0002, which split content from installation.

```
programs/agents  source: roles/ profiles/ skills/ instructions/ mcp/
                 lib/: parse, check, fold, passes      [pure, no vendor]
        |  agents.fold [ profiles ]  -> one checked, host-narrowed profile
        v
programs/<vendor>  default.nix: flavors (profile list + vendor settings)
                   codegen/  IR -> vendor format       [pure]
                   link/     store paths into $HOME    [effect]
                   load/     start or reload the agent [effect]
```

## Decisions

- **A profile is one setup's vendor-free part**: `skills`, `instructions`,
  `mcp`, `runtime`, `secretFiles`. One folder each,
  `profiles/<name>/profile.nix`, found by `readDir`: `base`, `web-ui`, `pm`,
  `factory`. There is no `ts` profile: `claude-ts` is `base` plus a Claude
  plugin, which is a vendor setting.
- **A flavor lists profiles and folds them with `append`**
  (`claude-pm = [ base web-ui pm ]`). Profiles are deltas and never import each
  other, so what a flavor gets is read off one list, not an import chain.
- **Conflicts throw.** One key with two different values is an eval error, never
  last-writer-wins; the same value twice is fine. Silent precedence would make
  the list order a hidden setting.
- **Layer order.** Instructions are fragments at a layer, rendered stably sorted
  `agent < context < role < topic`. Profile prose is `context`; `lead.md` is the
  lead's role; topics are last. The lead gets `forAll` and `forLead`, a role
  `forAll` and its own fragments.
- **Dedup is a guard, not a transformer.** The monoids already keep the first
  occurrence; `passes/dedup.nix` throws if a folded profile still holds a skill
  twice or one file at two layers, which the monoid cannot see.
- **The vendor rule is transitive.** Nothing under `programs/agents` may reach
  `programs/claude-code`, `opencode` or `codex`, even through another program
  (Deslop `agents-name-no-vendor`). Roles climb a ladder: a role reads its own
  folder and `shared/` above it, never another role (`roles-climb-the-ladder`).
- **Names.** `mkFragment { layer; file; }`, `mkInstructions { forAll; forLead; }`,
  and `append` for the monoid operation of instructions and profiles alike.
- **Parse before the first effect.** A missing MCP secret aborts the launch
  before `~/.claude` is written. Before this, the wrapper wrote skills,
  `CLAUDE.md` and `settings.json` first and left a half-switched flavor.

## Considered options

- **One profile per host.** Rejected: hosts share most of a setup, so each would
  repeat `base`. A host picks flavors, and a flavor lists profiles.
- **Last-writer-wins merge.** Rejected for the hidden order above.
- **`extraInstructions` and per-flavor skill lists in the Claude backend.**
  Removed: they were frontend data living in a backend, out of reach of the next
  vendor.

## Consequences

- A new vendor is `programs/<vendor>/{default.nix,codegen,link,load}` and
  `adapters/<vendor>.nix`; `programs/agents` does not change.
- `.claude/rules/agents-*.md`, `claude-code-*.md` and `qa.md` hold the
  working detail, one rule per folder, so an agent loads only the rules for
  what it is working on.

Follow-ups, not done:

- **`load/applies.nix` has no consumer.** It says when each written file reaches
  a running session (`Live | NextSession | Restart`) and is checked, but nothing
  acts on it yet, such as restarting the factory's servers.
- **Role-private skills on Claude.** The tree allows a skill only one role
  preloads, but whether `skillOverrides` `"off"` also blocks a role's preload is
  unknown, so none is installed that way.
- **The shared `~/.claude` race on the Macs.** All flavors write one
  `~/.claude`, so the flavor launched last wins, and a rebuild resets live
  sessions. Candidates: per-launch `--settings` and `--mcp-config` with
  `--strict-mcp-config`, or `CLAUDE_CONFIG_DIR` per flavor; unknown whether
  `claude remote-control` honours them.
- **OpenCode and Codex backends** do not exist yet; their paths are already in
  the backend rule's scope.
