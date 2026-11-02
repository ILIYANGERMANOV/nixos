---
paths:
  - "programs/agents/**"
  - "adapters/agents.nix"
---

## Agents frontend

**`programs/agents/` is the source language and the frontend of the agent
compiler. It names no vendor, no host and no `$HOME` path, and installs
nothing.** Why, and how a backend consumes it: `docs/adr/0011-agent-compiler.md`.

Nothing in `programs/agents` may reach `programs/claude-code`, `opencode` or
`codex`, even through another program (Deslop `agents-name-no-vendor`).
`adapters/agents.nix` is its only adapter: it injects `flake = false` inputs as
`externalSrcs`, `playwright`'s `qa` and the host's `secrets`.

### Source

- `instructions/agent.md` - what every agent gets, subagent roles included.
  `lead.md` and `topics/trivial.md` are for the agent leading a session, with
  `trivial.md` also in `review-lead`. Plain committed markdown.
- `profiles/<name>/profile.nix` - one folder per profile, found by `readDir`.
  A profile is the vendor-free part of one setup: `skills`, `instructions`,
  `mcp` (server names), `runtime` (packages on PATH) and `secretFiles`
  (variable -> secret name). `base` (every flavor: the shared skills,
  `agent.md`, `lead.md`, `trivial.md`, `runtime`, `secretFiles`), `web-ui`
  (figma), `pm` (`self-improve`, linear, superhuman-docs) and `factory`
  (`10x-engineer`, `self-improve`, `android`, its `agent.md` in `forAll` and
  its `lead.md` for the lead only). Profiles are deltas and never import each
  other; a backend's flavor lists the ones it gets.
- `roles/<name>/` - one role: `role.nix`, its record, and `role.md`, its prose.
  Adding a role is adding its folder; `shared/` is not a role.
- `skills/` - the catalog (below). `mcp/default.nix` - the MCP catalog.

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
- `passes/budget.nix` - the agnostic size budget (below).
- `role.nix` - `mkRole` throws on any unknown field, capability, tier or
  effort: a backend's format may ignore a misspelled field, and a dropped
  tool list would widen a role.
- `mcp.nix` - MCP without a wire format: `mkLocal`, `mkRemote`, `selectServers`
  (an unknown name throws), `availableServers` (a server whose secret the host
  lacks is dropped silently) and `provided` (the same for secret files).

`default.nix` is the surface: `profiles`, `fold` (profile `fold`, the dedup
guard, then narrowed to this host's `secrets`: `mcp` and `secretFiles` hold
paths), `renderLead`, `renderRole`, `skills`, `roles`, `budget` and `check`.
`checks.agents` proves every law and every rejection above.

### Roles and the ladder

- A `role.nix` is a function of `{ role, topics }` returning a plain record:
  `name` (the folder's), `description`, `instructions` (role and topic
  fragments; the renderer puts `forAll` in front), `capabilities`
  (`read edit shell web delegate`), `skills`, `tier` and `effort`.
- **The ladder.** A role reads only its own folder and any `shared/` at or above
  it, never another role (Deslop `roles-climb-the-ladder`). Prose moves to
  `shared/` at its second reader, never in anticipation, and back out when one
  is left: `shared/building.md` serves `implementer` and `fixer`.
- A role gets `delegate` only if its flow spawns agents: `implementer` splits a
  large slice and `review-lead` spawns `reviewer`s.
- `refactor`, the dry run, a fresh check, a delegated `engineer` and the `/qa`
  agents have no role yet and stay general-purpose.
- Trivial tasks spawn no researcher and skip the process skills, by
  `instructions/topics/trivial.md`. It keeps skill and instruction edits out of
  Trivial unless they are typos, so a change here is never Trivial.

### Skills

- `skills/default.nix` - the catalog: third-party sources with an explicit
  allowlist, plus the list of enabled custom skills.
- `skills/lib.nix` - discovery, collision detection, farm and validation. No
  policy. `checks.agents` validates every installed skill: frontmatter,
  `name` matching its directory, `description` within 1024 characters.
- `skills/custom/<name>/SKILL.md` - hand-written. Installed only once its name
  is in `custom`, so drafts can stay committed (`skills/custom/README.md`).

External sets are flake inputs, not `fetchFromGitHub`: `allow-import-from-derivation`
is false, so only a plain store path can be `readDir`'d, which is what lets the
allowlist use bare skill names searched for recursively.

Every flavor gets every shared skill, `ui-coding` included: a model-invoked
skill costs only its description. `self-improve` is in `pm` and `factory` only:
it measures the machine's own transcripts, needs `python3` from
`modules/home/terminal.nix` on the Macs, and its `scripts/analyze.py` is tested
by `checks.python-tests` on synthetic transcripts only (this repo is public).
`10x-engineer` is in `factory` only and invokes `engineer` with the Skill tool,
so `engineer` must never set `disable-model-invocation`.

### MCP, runtime and secret files

A catalog entry is **local** (`mkLocal`) or **remote** (`mkRemote`), tagged by
`type`. A local server's `env` maps a variable to the **name** of the secret
that fills it; no `env` means no secrets, so availability is "every secret it
names is declared" and holds vacuously. That is the only way to gate a server
to a host. A remote server authenticates out-of-band (OAuth), carries
`env = { }` and so is on every host that runs a flavor listing it. `mkRemote`
takes only a `url`; a static bearer token in `headers` is what would let a
remote server be host-gated, and nothing needs it yet.

`runtime` is put on PATH by the flavor. `base` has `programs/playwright`'s `qa`:
`qa-node` (Node resolving `playwright` with nixpkgs' Chromium, `viem` and the
`qa-wallet` helper from any directory) and `qa-mp4` (ffmpeg). The environment
lives inside `qa-node`, never the session, so a project's own Playwright keeps
its own browsers.

`qa-kit`, `qa-wallet` and the `qa-check*` scripts are strict TypeScript,
compiled to ES modules in the derivation, because Node refuses type stripping
under `node_modules`. Libraries come from `pnpm-lock.yaml` at exact versions;
`tsgo` and Biome from nixpkgs. After changing the lock file (`pnpm install
--lockfile-only` in the dev shell), update `pnpmDeps.hash` in
`programs/playwright/default.nix`. `playwright` in `package.json` is for types
only: keep it at nixpkgs' `playwright-test` version. `checks.ts-test` is the
unit layer, `checks.qa` the end-to-end one.

`secretFiles` maps a variable to a secret **name**, for a program that reads
the file itself: the backend exports the decrypted file's **path**, never its
value (`QA_EVM_KEY_FILE` -> `qa-sepolia-key`, on `macos-work` only). A host
without the secret gets no variable.

### Size budget

**`budget.json` holds ceilings, in bytes, on what every agent carries**, named
by no vendor: each flavor's instructions, each role's instructions with what it
preloads and reads, and this repo's root `CLAUDE.md`. `checks.claude-config`
fails above them; `just skill-budget` prints the table. Raising a ceiling is
allowed, and is the visible diff that makes the cost a decision. Keep root
`CLAUDE.md` small: detail belongs in a `.claude/rules/` file.

### Adding things

- **Third-party skill**: add the repo as a `flake = false` input in `flake.nix`,
  forward it through `adapters/agents.nix` as `externalSrcs.<name>`, add a
  source entry in `skills/default.nix`, then the skill name to a profile.
- **Custom skill**: create `skills/custom/<name>/SKILL.md`, add `<name>` to
  `custom`, then to a profile.
- **MCP server**: add a `mkLocal` or `mkRemote` entry to `mcp/default.nix`,
  then its name to a profile's `mcp`; a secret goes through
  `myConfig.secrets` (`.claude/rules/secrets.md`).
- **Tool on PATH**: add the package to a profile's `runtime`.
- **Role**: add `roles/<name>/{role.nix,role.md}`; the backends render it.
- **Profile**: add `profiles/<name>/profile.nix`, then list it in a flavor.
