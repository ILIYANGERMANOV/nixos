---
paths:
  - "programs/software-factory/**"
  - "programs/skills-link/**"
  - "programs/claude-code/**"
  - "programs/kotlin/**"
  - "modules/nixos/server/**"
  - "modules/home/factory/**"
  - "hosts/software-factory/**"
  - "just/software-factory.just"
  - "docs/SOFTWARE-FACTORY.md"
  - "docs/adr/0007-*"
---

## Software factory

**`software-factory` is a headless server whose agents are driven from a phone
via Claude Code Remote Control. Its configuration must never change another
host.** See `docs/adr/0007-software-factory.md` (design, trust boundaries,
accepted risks) and `docs/SOFTWARE-FACTORY.md` (runbook).

- `lib.mkNixosServer` imports `modules/nixos/server/` and no desktop module;
  nothing else imports that directory. The agent account's Home Manager profile
  is `modules/home/factory/`, its own import list - `modules/home/default.nix`
  is untouched by it.
- `programs/software-factory/` holds the logic: managed settings (billing and
  permission policy), the Remote Control launchers, `factory-ctl` (`ctl/`), the
  root deploy and maintenance scripts (`ops/`), the admin agent's project
  (`admin/`) and the egress nftables rules. `checks.software-factory`
  (`check.nix`, scenarios in `check.sh`) tests them.
  `checks.software-factory-activation` reads the relink hook off the host's Home
  Manager config, a lazy partial eval.
- **The admin agent runs the box; `factory-ctl` is its only tool.** Add an
  admin capability as a `factory-ctl` command with a scenario in `check.sh`,
  then a skill in `admin/skills/` that calls it. Skills there are
  project-scoped to `~/admin` on purpose - never add them to the shared skill
  catalog, which every agent of the account loads.
- **Deploys are pulled, never pushed.** `factory-deploy` (`modules/nixos/server/ops.nix`)
  polls this repository's GitHub deployments, verifies the commit is the tip
  of `main`, and switches behind a health gate. Root units it adds must set
  `restartIfChanged = false`, and Remote Control units keep
  `X-SwitchMethod = keep-old`, or a deploy kills its own caller.
- **The Android toolchain is global, never per repository.** `programs/kotlin`
  holds it: `workstation` (JDK 17, kotlin-lsp, ktlint, adb) for every host,
  `android` (store SDK, Gradle memory settings, konan's nix-ld libraries) for
  the factory only, wired by `modules/home/factory/android.nix`, the Remote
  Control units' environment and `nix-ld.nix`. The SDK licence is accepted
  there, not in nixpkgs' config. A missing SDK component is added to that SDK.
- The `claude-factory` flavor is `factory` in `programs/claude-code`, deliberately
  outside `packages` so no other host installs it.
- The server has its own sops age key; `secrets/common.yaml` is not encrypted
  to it.
- **This repository is public.** Never commit IP addresses, tailnet names,
  private repository names or anything that maps the server's attack surface
  beyond what the Nix config itself states. Private repositories are added on
  the box with `factory-ctl start` (the admin agent's `/start-repo`).
- Recipes are in `just/software-factory.just`.
