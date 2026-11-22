---
paths:
  - "programs/agents/instructions/**"
  - "programs/agents/lib/**"
---

## Agents: instructions and laws

### Instructions

- `instructions/agent.md` - what every agent gets, subagent roles included.
  `lead.md`, `topics/fuel.md` and `topics/fuel-lead.md` are for the agent
  leading a session, with `fuel.md` also in the roles that vary by Fuel:
  `engineer`, `researcher`, `refactorer`, `review-lead`, `reviewer`, and
  `fuel-lead.md` (the run rules: Confirm, skips, `extend`) also in `engineer`,
  which runs a flow. Plain committed markdown.
- `topics/engineering.md` - the coding style and engineering principles, in
  the lead and every role that writes, reviews or researches code (all but
  `checker`). Its `@tests@` becomes the store path of
  `topics/engineering/tests.md` through `replaceVars`.
- `topics/fuel.md`'s Fuel table is the only place a Fuel changes a step;
  skills and roles read their row. Its trivial rule keeps skill and
  instruction edits beyond a typo out of Low's skips, so a change here never
  skips a step.

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
  file, the table and self-improve aside, holds a Fuel table row, a `<level>:` branch
  it does not allow or a self-activation phrase.
- `passes/budget.nix` - the agnostic size budget (`agents-frontend.md`).
- `role.nix` - `mkRole` throws on any unknown field, capability, operation,
  tier, effort or cache: a backend's format may ignore a misspelled field, and a dropped
  tool list would widen a role.
- `derive.nix` - derived roles, stage A (#351 section 8): a role's
  capabilities, skills, operations and prose are the union of its rows in
  `flows/steps.nix`, its `steps` and `offFlow` work; `engineer` and `review-lead` preload only the prose
  every step needs. Its check holds the laws `derived_role_holds_every_step_need`,
  `derived_role_holds_nothing_else` and `derived_equals_recorded_golden`.
- `mcp.nix` - MCP without a wire format: `mkLocal`, `mkRemote`, `selectServers`
  (an unknown name throws), `availableServers` (a server whose secret the host
  lacks is dropped silently) and `provided` (the same for secret files).

`default.nix`'s `fold` runs the profile `fold`, the dedup guard, then narrows
to this host's `secrets`: `mcp` and `secretFiles` hold paths.
