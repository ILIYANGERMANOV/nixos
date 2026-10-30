# QA

## Run the app

This repository is Nix configuration. It has no web app, no server to start and
no URL, so there is no browser run. Running it means building what the PR
changes and reading the result. Start from a checkout of the PR on Linux.

| The PR changes | Run | Ready when |
| --- | --- | --- |
| `programs/nvim` | the real editor, below | `nvim --version` prints and the headless start ends cleanly |
| `programs/<x>` | `nix build --no-link .#checks.x86_64-linux.<x>`, names in the `CLAUDE.md` Checks ladder | the build exits 0 |
| `programs/software-factory`, `factory-ctl` | `nix build --no-link .#checks.x86_64-linux.software-factory`: the scenarios in `check.sh`, against a real git and doubles | the build exits 0 |
| `.github/` | `nix build --no-link .#checks.x86_64-linux.zizmor` | the build exits 0 |
| `modules/`, `hosts/` | the host evaluation in the `CLAUDE.md` Checks ladder | it prints a store path |

The real editor, as the factory host builds it:

```sh
nvim=$(nix build --no-link --print-out-paths \
  .#nixosConfigurations.software-factory.config.home-manager.users.factory.programs.nixvim.build.package)
"$nvim/bin/nvim" --version
"$nvim/bin/nvim" --headless +qa
```

## Key flows

- `nix build --no-link .#checks.x86_64-linux.nvim-search` builds the same editor
  and presses real keys in it.
- `nix develop -c just quick-check` runs lint, architecture, format and every
  `checks` derivation for this system.

## Quirks

- Flakes see only files git tracks. Run `git add -N <new files>` before a build.
- `factory-ctl` on the path is the deployed one, not the PR's. `status` reads
  the box and proves nothing about a PR. Leave its other commands to the admin
  agent.
- Proof is command output, not video.

## Out of scope

- A host switch or activation. Deploys are pulled: the server takes the tip of
  `main` behind its health gate, so a PR never reaches a host. Never run
  `darwin-rebuild`, `nixos-rebuild`, `factory-deploy` or `factory-ctl deploy`.
- Anything needing a real secret, the macOS Keychain or a darwin host.
- An MCP OAuth login, or a language server serving a real project: the Neovim
  checks start no server.
