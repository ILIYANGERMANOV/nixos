---
paths:
  - "programs/agents/instructions/**"
  - "programs/agents/lib/**"
---

## Agents: instructions and laws

### Instructions

- `instructions/agent.md` - what every agent gets, subagent roles included.
  `lead.md`, `topics/trivial.md` and `topics/quality.md` are for the agent
  leading a session, with `trivial.md` also in `engineer` and `review-lead`, and
  `quality.md` in the roles that vary by mode: `engineer`, `researcher`,
  `implementer`, `refactorer`, `review-lead`, `reviewer`. Plain committed
  markdown.
- `topics/quality.md`'s Quality table is the only place a mode changes a step;
  skills and roles read their row. `Size: Trivial` skips steps, by
  `topics/trivial.md`. It keeps skill and instruction edits out of Trivial
  unless they are typos, so a change here is never Trivial.

### Laws (`lib/`)

- `instructions.nix` - the instructions monoid. `mkFragment { layer; file; }` is
  one file at a layer: `agent < context < role < topic`; an unknown layer
  throws. `mkInstructions { forAll; forLead; }` holds two ordered sets, `append`
  concatenates each keeping the first occurrence, `empty` is its identity.
  `renderLead` gives the lead `forAll` and `forLead`, `renderRole` a role
  `forAll` and its own fragments, both sorted stably by layer.
- `profile.nix` - the profile monoid. `mkProfile` throws on an unknown field, or
  a skill or MCP server not in its catalog. `append` unions lists keeping the
  first occurrence, appends instructions, and **throws when one key gets two
  different values**, never last-writer-wins. `empty` is its identity, `fold`
  appends a list.
- `passes/dedup.nix` - a guard, not a transformer: it throws if a folded profile
  still holds a skill twice or one file at two layers.
- `passes/modes.nix` - a guard: it throws if a skill, role or instructions
  file, the table and self-improve aside, holds a mode table row, the old
  `, Trivial` suffix or a self-activation phrase.
- `passes/budget.nix` - the agnostic size budget (`agents-frontend.md`).
- `role.nix` - `mkRole` throws on any unknown field, capability, tier or
  effort: a backend's format may ignore a misspelled field, and a dropped
  tool list would widen a role.
- `mcp.nix` - MCP without a wire format: `mkLocal`, `mkRemote`, `selectServers`
  (an unknown name throws), `availableServers` (a server whose secret the host
  lacks is dropped silently) and `provided` (the same for secret files).

`default.nix`'s `fold` runs the profile `fold`, the dedup guard, then narrows
to this host's `secrets`: `mcp` and `secretFiles` hold paths.
