---
paths:
  - "programs/agents/mcp/**"
---

## Agents: MCP catalog

`mcp/default.nix` is the catalog. An entry is **local** (`mkLocal`) or
**remote** (`mkRemote`), tagged by `type` (constructors in `lib/mcp.nix`).

A local server's `env` maps a variable to the **name** of the secret that fills
it; no `env` means no secrets, so availability is "every secret it names is
declared" and holds vacuously. That is the only way to gate a server to a host.
A remote server authenticates out-of-band (OAuth), carries `env = { }` and so is
on every host that runs a flavor listing it. `mkRemote` takes only a `url`; a
static bearer token in `headers` is what would let a remote server be
host-gated, and nothing needs it yet.

### Adding an MCP server

Add a `mkLocal` or `mkRemote` entry to `mcp/default.nix`, then its name to a
profile's `mcp`; a secret goes through `myConfig.secrets`
(`.claude/rules/secrets.md`).
