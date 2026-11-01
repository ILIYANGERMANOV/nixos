---
paths:
  - "modules/secrets.nix"
  - "secrets/**"
  - "hosts/**"
  - "just/secrets.just"
  - "docs/SOPS.md"
  - "docs/adr/0005-*"
  - "programs/claude-code/default.nix"
  - "programs/claude-code/lib.nix"
  - "programs/claude-code/secret-guard*"
  - "modules/home-manager.nix"
  - "modules/home/claude-code.nix"
  - "modules/home/factory/claude-factory.nix"
  - "modules/nixos/user.nix"
  - "modules/nixos/server/ops.nix"
  - "modules/nixos/server/tailscale.nix"
  - "modules/nixos/server/users.nix"
---

## Secrets

**`myConfig.secrets` is the only door to `sops.secrets`. Never write
`sops.secrets` by hand.**

Every secret has a **scope**, which picks the file it is read from:
`global` -> `secrets/common.yaml` (every host), `host` -> `secrets/hosts/<hostname>.yaml`
(only hosts that declare it). Names are bare: `figma-token`, never
`figma-token-macos-work`. The file already says which host it belongs to.

`modules/secrets.nix` holds the registry, the age key path and the expansion
into `sops.secrets`. A host declares what it provides in one line
(`myConfig.secrets.figma-token = { };`) and says nothing at all about secrets it
does not have. `scope` is explicit rather than inferred because the module
system merges all definitions and erases where each came from.

**A declaration is a promise, and absence is a feature.** Declaring a secret
asserts the value exists in the matching file; a missing file is a build error.
Not declaring one is how a host opts out, so anything depending on a secret must
key off its availability and disable itself where it is absent - never assume
every host has every secret, and never add a placeholder value to make a build
pass. That placeholder is exactly what this design removed.

Home Manager receives `secretsConfig` (`name -> path`, declared secrets only)
through `extraSpecialArgs`, alongside `userConfig` and `themeConfig`.
`programs/` takes it as a plain parameter and stays host-agnostic: it gates on
what it was handed, it never looks a host up. `programs/claude-code` is the
worked example - catalog entries name the secrets they need
(`env.FIGMA_API_KEY = "figma-token"`), unavailable entries are dropped before
any flavor sees them, and names are validated against the full catalog so a typo
still aborts while an unavailable server stays silent.

**Paths only, never values.** `sops.secrets.<n>.path` is a build-time string and
producing it decrypts nothing. `builtins.readFile` on a decrypted path would
bake plaintext into a world-readable store path: do not do it. Secrets are read
at runtime by the process that needs them.

All hosts share one age key today, so the per-host split is organisational, not
a trust boundary. See `docs/adr/0005-host-scoped-secrets.md` for the upgrade
path, and `docs/SOPS.md` for the day-to-day recipes.
