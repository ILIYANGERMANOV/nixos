{
  description = "NixOS & dev-shell configuration";

  inputs = {
    # Tracks the *darwin* channel branch, not nixos-26.05. Both fast-forward
    # along release-26.05, but different Hydra jobsets advance them: the
    # NixOS/Linux one advances nixos-26.05, the darwin one advances
    # nixpkgs-26.05-darwin. A rev on nixos-26.05 is only guaranteed to have
    # *Linux* binaries in cache.nixos.org; darwin coverage is incidental, and a
    # miss means building Swift and .NET from source for hours.
    # See docs/adr/0004-darwin-tracks-the-darwin-channel.md before repointing
    # this, and docs/NON-DARWIN-NIXOS-ISSUES.md for what it costs lenovo-old.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nixvim = {
      url = "github:nix-community/nixvim/nixos-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Intentionally NOT following nixpkgs: llm-agents tracks nixpkgs-unstable
    # so we always get the latest claude-code release. flake.lock pins the rev.
    llm-agents.url = "github:numtide/llm-agents.nix";
    herdr = {
      url = "github:ogulcancelik/herdr";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Deslop, the architecture linter `just check` runs. Its own flake packages
    # the prebuilt release binaries. See
    # docs/adr/0008-deslop-enforces-the-architecture.md.
    deslop = {
      url = "github:Ivy-Apps/deslop";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Not a flake — a plain repo of SKILL.md directories. `flake = false` keeps it
    # a regular store path, so skills can be discovered with builtins.readDir at
    # eval time. A fetchFromGitHub result could not: modules/nix.nix sets
    # allow-import-from-derivation = false. flake.lock pins the rev.
    mattpocock-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };
  };

  outputs =
    { self, ... }@inputs:
    let
      lib = import ./lib {
        inherit inputs;
        root = self;
      };

      # Every software factory, by hostname, with the platform it runs on
      # (lib.mkNixosServer). The deploy workflow's host choice is the only
      # other list of them, held to this one by checks.factory-deploy-hosts.
      factories = {
        software-factory = "hetzner";
        software-factory-lenovo = "thinkpad-t15p";
      };
    in
    {
      # `nix fmt` - treefmt, the one door to every formatter.
      formatter = lib.forAllSystems (pkgs: import ./programs/tech-checks/formatter.nix { inherit pkgs; });

      # `nix flake check` (run by `just check` in CI) validates every installed
      # SKILL.md - frontmatter present, name matches the directory, description
      # within the Agent Skills limit - the Claude Code MCP catalog logic, the
      # Neovim TypeScript server routing, the Neovim search config, and the
      # Playwright environment. The `<tech>-<kind>` checks at the end are the
      # groups `just tech <tech>` builds, each with no host evaluation; CI builds
      # this set on aarch64-linux (`check`) and x86_64-linux (`checks-x86_64`).
      checks = lib.forAllSystems (
        pkgs:
        let
          # Every Neovim check shares one build of the real editor.
          nvimChecks = import ./programs/nvim/check.nix {
            inherit pkgs inputs;
            root = self;
          };
        in
        {
          agents =
            (import ./adapters/agents.nix {
              inherit inputs pkgs;
              root = self;
            }).check;

          # The ~/.claude.json MCP structure and the secret file guard, against
          # synthetic servers and secret paths.
          claude-code = import ./programs/claude-code/check.nix { inherit pkgs; };

          # The real Claude Code configuration: no catalog skill hidden, and
          # every measured size under its committed ceiling.
          claude-config =
            (import ./adapters/claude-code.nix {
              inherit inputs pkgs;
              root = self;
            }).check;

          # That the Playwright environment given to agent sessions resolves
          # `require('playwright')` from an empty directory and finds Chromium,
          # which on Linux it also launches headless.
          playwright = import ./programs/playwright/check.nix { inherit pkgs; };

          # Which TypeScript language server claims a project root - vtsls for
          # the tsserver era, `tsc --lsp` for TypeScript 7 - against fixture
          # roots in a real headless Neovim.
          nvim-typescript = nvimChecks.typescript;

          # That the snacks.picker grep config survives nixvim's freeform
          # `settings` into Lua, and that every content-search key dispatches
          # to it. `plugins.snacks.settings` types no picker options, so a
          # misspelled key would otherwise ship silently.
          nvim-search = nvimChecks.search;

          # That a .py file gets basedpyright and ruff running nixpkgs' binaries,
          # ruff's hover and basedpyright's organize imports off, ruff as its
          # formatter, and that <leader>tt runs `pytest <file>`.
          nvim-python = nvimChecks.python;

          # Spell check. Pinned to the locked nixpkgs deliberately: typos' dictionary
          # is its product and grows with every release, so a floating version could
          # turn CI red with no change to this repo. Sees only the committed
          # `.typos.toml`, never the private global allowlist.
          typos = (import ./programs/typos { inherit pkgs; }).mkCheck self;

          # That the deploy workflow's host options (`all`, then every factory)
          # and its FACTORIES list are `factories` above.
          factory-deploy-hosts =
            pkgs.runCommand "factory-deploy-hosts" { nativeBuildInputs = [ pkgs.yq-go ]; }
              ''
                workflow=${./.github/workflows/deploy-factory.yml}
                options=$(yq -o=json -I=0 '.on.workflow_dispatch.inputs.host.options' "$workflow")
                all=$(yq '.jobs.request.env.FACTORIES' "$workflow")
                [ "$options" = '${
                  builtins.toJSON ([ "all" ] ++ builtins.attrNames factories)
                }' ] && [ "$all" = '${toString (builtins.attrNames factories)}' ] || { echo "ERROR: deploy-factory.yml's host options or FACTORIES differ from factories in flake.nix" >&2; exit 1; }
                touch "$out"
              '';

          # That the GHCi scope and slice names agree across three files that
          # build apart: ghcid.sh starts a ghcid-<escaped dir> scope in
          # ghci.slice, the factory's ctl/memory.sh finds and stops it, and the
          # factory's home module defines the slice.
          ghci-scope-names = pkgs.runCommand "ghci-scope-names" { } ''
            has() { grep -qF -- "$2" "$1" || { echo "ERROR: $1 lacks: $2" >&2; exit 1; }; }
            has ${./programs/haskell/ghcid.sh} '--unit="ghcid-$(systemd-escape --path "$PWD")"'
            has ${./programs/haskell/ghcid.sh} '--slice=ghci.slice'
            has ${./programs/software-factory/ctl/memory.sh} 'unit="ghcid-$(systemd-escape --path "$1")"'
            has ${./programs/software-factory/ctl/memory.sh} 'stop ghci.slice'
            has ${./modules/home/factory/claude-factory.nix} 'slices.ghci = {'
            touch "$out"
          '';

          # Static analysis of .github/: pinned actions, token permissions,
          # credential persistence. Offline, against `.github/zizmor.yml`.
          zizmor = import ./programs/zizmor/check.nix {
            inherit pkgs;
            src = self;
          };

          # Markdown links to a missing file or #anchor fail the build.
          # --offline: local links only, so the sandbox needs no network.
          # --include-fragments: #anchor targets must exist.
          # --hidden: scan .claude/ and .github/ too.
          # cacert: lychee builds its HTTP client even offline, and that needs
          # CA certificates.
          links =
            pkgs.runCommand "links-check"
              {
                nativeBuildInputs = [
                  pkgs.lychee
                  pkgs.cacert
                ];
              }
              ''
                cd ${self}
                lychee --offline --include-fragments --hidden .
                touch "$out"
              '';
        }
        # claude-kategory builds and guards both logins: see
        # kategory/check.nix. Where `llm-agents` has a Claude Code.
        // pkgs.lib.optionalAttrs (self.packages.${pkgs.stdenv.hostPlatform.system} ? claude-kategory) {
          kategory = import ./programs/claude-code/kategory/check.nix {
            inherit pkgs;
            inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) claude-kategory;
          };
        }
        # opencode-kategory run offline against what it promises: see
        # programs/opencode/check.sh. Where `llm-agents` has an OpenCode.
        // pkgs.lib.optionalAttrs (self.packages.${pkgs.stdenv.hostPlatform.system} ? opencode-kategory) {
          opencode =
            (import ./adapters/opencode.nix {
              inherit inputs pkgs;
              root = self;
            }).check;
          # opencode-kategory-headless runs to the end with nobody there: see
          # programs/opencode/check-headless.sh.
          opencode-headless =
            (import ./adapters/opencode.nix {
              inherit inputs pkgs;
              root = self;
            }).checkHeadless;
        }
        # That a .kt file gets kotlin_lsp running the binary programs/kotlin
        # packages, ktlint as its formatter, and that <leader>tt runs
        # `./gradlew test` in a Gradle project. Only where a kotlin-lsp release
        # is pinned.
        // pkgs.lib.optionalAttrs (nvimChecks ? kotlin) { nvim-kotlin = nvimChecks.kotlin; }
        # The /qa runtime: the wallet helper against a synthetic dApp with a
        # generated key (EIP-6963 discovery, connect, signatures that verify,
        # the key absent from the page, a receipt wait), a recording transcoded
        # to mp4 with its static lead-in trimmed, the contact sheet, and one
        # session browser shared by probe processes with redacted capture.
        # Linux only, as the Darwin sandbox cannot launch Chromium.
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux (
          {
            qa = import ./programs/playwright/qa-check.nix { inherit pkgs; };
          }
          # `<factory>-activation`: that the factory's home activation runs the
          # relink: a farm factory-gc may collect is otherwise never moved off.
          # The only checks that evaluate a host, so `just quick-check` pays for
          # them.
          // pkgs.lib.mapAttrs' (
            host: _:
            pkgs.lib.nameValuePair "${host}-activation" (
              assert pkgs.lib.hasInfix "factory-relink-skills"
                self.nixosConfigurations.${host}.config.home-manager.users.factory.home.activation.relinkClaudeSkills.data;
              pkgs.emptyFile
            )
          ) factories
        )
        // import ./programs/tech-checks {
          inherit pkgs;
          # Only its hook adapter, which needs no OpenCode package: python-tests
          # runs it on every system.
          opencode = import ./adapters/opencode.nix {
            inherit inputs pkgs;
            root = self;
          };
          claude = import ./adapters/claude-code.nix {
            inherit pkgs inputs;
            root = self;
            # Synthetic paths, never read, so a wrapper's secret branches are in
            # the text `shell-embedded` lints.
            secrets = {
              figma-token = "/run/secrets/figma-token";
              qa-sepolia-key = "/run/secrets/qa-sepolia-key";
            };
          };
          inherit
            (import ./adapters/agents.nix {
              inherit inputs pkgs;
              root = self;
            })
            guards
            kernel
            kernelDev
            state
            ;
        }
      );

      # `factories` for the just recipes, which validate a host against it.
      lib = { inherit factories; };

      # The kernel's runners, fastest first: `nix run .#kernel-quick-typecheck`,
      # `kernel-quick-test`, `kernel-build`, `kernel-test`, `kernel-lint` and
      # `kernel-format`. See .claude/rules/haskell.md.
      apps = lib.forAllSystems (
        pkgs:
        (import ./adapters/agents.nix {
          inherit inputs pkgs;
          root = self;
        }).kernelDev.apps
      );

      # `just mutation-diff` and `just mutation` run it. Not a check: see
      # programs/mutation/default.nix.
      packages = lib.forAllSystems (
        pkgs:
        let
          inherit (pkgs.stdenv.hostPlatform) system;
        in
        {
          mutation =
            (import ./programs/mutation { inherit pkgs; }).runner
              (import ./adapters/agents.nix {
                inherit inputs pkgs;
                root = self;
              }).state;
        }
        # `just probe-agents-hooks` runs it, see its default.nix. Not on
        # x86_64-darwin: `llm-agents` has no package there.
        // pkgs.lib.optionalAttrs (inputs.llm-agents.packages ? ${system}) {
          probe-agents-hooks = import ./programs/claude-code/hooks/contract {
            inherit pkgs;
            inherit (inputs.llm-agents.packages.${system}) claude-code;
          };
          # The factory's harness in ~/.claude-kategory, for anyone with Nix:
          # `nix profile add github:ILIYANGERMANOV/nixos#claude-kategory`.
          claude-kategory =
            (import ./adapters/claude-code.nix {
              inherit inputs pkgs;
              root = self;
            }).kategory;
          # The same harness in OpenCode on DeepSeek, in ~/.opencode-kategory:
          # `nix run github:ILIYANGERMANOV/nixos#opencode-kategory`.
          opencode-kategory =
            (import ./adapters/opencode.nix {
              inherit inputs pkgs;
              root = self;
            }).kategory;
          # The same for a run with nobody there, such as a CI job:
          # `opencode-kategory-headless run --auto "<prompt>" </dev/null`.
          opencode-kategory-headless =
            (import ./adapters/opencode.nix {
              inherit inputs pkgs;
              root = self;
            }).kategoryHeadless;
        }
      );

      devShells = lib.forAllSystems (
        pkgs:
        let
          default = import ./shells/default.nix { inherit pkgs inputs; };
          inherit
            (import ./adapters/agents.nix {
              inherit inputs pkgs;
              root = self;
            })
            kernelDev
            ;
        in
        {
          inherit default;
          # The kernel's GHC with its deps, cabal and ghcid: its quick runners'
          # session runs in it.
          kernel = kernelDev.shell;
          # What direnv loads (.envrc): `default` plus the kernel's shell, so an
          # editor's HLS finds a matching `ghc` and cabal. CI keeps the lean
          # `default`.
          dev = pkgs.mkShell {
            inputsFrom = [
              default
              kernelDev.shell
            ];
          };
          nixos-install = import ./shells/nixos-install.nix { inherit pkgs inputs self; };
          darwin-install = import ./shells/darwin-install.nix { inherit pkgs inputs self; };
        }
      );

      nixosConfigurations = {
        lenovo-old = lib.mkNixosSystem "lenovo-old" "x86_64-linux" { hardware = "thinkpad-t15p"; };
        # next-host = lib.mkNixosSystem "next-host" "x86_64-linux" { };
      }
      // builtins.mapAttrs (
        host: platform: lib.mkNixosServer host "x86_64-linux" { inherit platform; }
      ) factories;

      darwinConfigurations = {
        macos-main = lib.mkDarwinSystem "macos-main" "aarch64-darwin" { };
        macos-work = lib.mkDarwinSystem "macos-work" "aarch64-darwin" { };
      };
    };
}
