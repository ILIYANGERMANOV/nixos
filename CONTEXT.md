# NixOS Configuration

A mono-repo that assembles NixOS, nix-darwin and dev-shell configurations for a
small fleet of personal and work machines from one flake.

## Language

### Machines

**Host**:
One named machine the flake can build, declared in `hosts/<name>/`. Carries
identity only - hostname and user - never configuration.
_Avoid_: machine, system, box, node

**Flavor**:
A named wrapper binary around a single agent (`claude`, `claude-ts`,
`claude-web-ui`) that owns its own settings, skills, instructions and MCP
servers for the duration of a launch.
_Avoid_: profile, variant, mode

### Secrets

**Secret**:
A named credential stored encrypted in the repo and decrypted on the host by
sops-nix. Its name is bare (`figma-token`), never qualified by host.
_Avoid_: token, credential, key

**Scope**:
Whether a secret is `global` (every host has it, stored in
`secrets/common.yaml`) or `host` (only hosts that opt in, stored in
`secrets/hosts/<hostname>.yaml`). Stated explicitly on every declaration.
_Avoid_: level, tier, visibility

**Declaration**:
A host entry in `myConfig.secrets` stating that it provides a secret. It is a
promise that the value exists in the matching file, not a request to create
one - a missing file is an error, not an absence.
_Avoid_: registration, definition

**Availability**:
Whether a given secret is declared on the host being built. Dependent
configuration reads availability and disables itself when a secret is absent,
rather than assuming every host has every secret.
_Avoid_: presence, enabled

**Password hash**:
The yescrypt digest a NixOS host authenticates its user against. Never the
password itself, which this repo never stores.
_Avoid_: password

### Agents

**Skill**:
A `SKILL.md` directory installed into an agent's skill directory, sourced either
from a pinned third-party set or from `programs/agents/skills/custom/`.

**Catalog**:
The declared set of things a flavor may draw from - MCP servers in
`programs/claude-code`, skills in `programs/agents/skills`. Naming something
absent from a catalog aborts evaluation; a catalog entry filtered out by
availability is silently absent instead.
_Avoid_: registry (reserved for `myConfig.secrets`), list

**Hook**:
A vendor-free program an agent runs at a session start or around a tool call,
declared in `programs/agents/hooks` and attached by a profile. It reads one
event and returns allow or deny, context and rewritten input.
_Avoid_: guard (a Claude-native hook in `programs/claude-code/hooks`)

**Dispatcher**:
The frontend's one entry point per event that runs that event's hooks in order
and folds their results, so every backend runs them the same way.
