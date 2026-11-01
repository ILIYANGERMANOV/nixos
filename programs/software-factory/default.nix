# The software factory: Claude Code agents serving git repositories over Remote
# Control, from one unprivileged account, plus the admin agent that runs the box
# and the root units it may start. Plain functions and derivations - no
# hosts, no users, no systemd units. modules/nixos/server and
# modules/home/factory wire them in. The agents' workflow instructions belong
# to the claude-factory flavor, in programs/claude-code/factory-instructions.md.
#
# The scripts call `systemctl` from PATH rather than bundling systemd: the
# server's units put the system profile on PATH, and it keeps them buildable -
# and testable by checks.software-factory - on every platform.
{
  pkgs,
  lib ? pkgs.lib,
}:

let
  shellCheck = import ../shell-check { inherit pkgs; };
  inherit (shellCheck) fragment;

  # Root-owned policy, installed at /etc/claude-code/managed-settings.json.
  #
  # Billing: only a claude.ai subscription login may be used. forceLoginMethod
  # makes Claude Code refuse to start when ANTHROPIC_API_KEY,
  # ANTHROPIC_AUTH_TOKEN or an apiKeyHelper is present, and allowedProviders
  # refuses every route to Claude but Anthropic's own API.
  #
  # Permissions: auto mode is the default and bypass mode cannot be entered at
  # all. The deny rules are a backstop against the obvious form of each action,
  # not a boundary - see docs/adr/0007-software-factory.md.
  managedSettingsValue = {
    forceLoginMethod = "claudeai";
    allowedProviders = [ "anthropic" ];
    permissions = {
      defaultMode = "auto";
      disableBypassPermissionsMode = "disable";
      deny = [
        "Bash(git push * main)"
        "Bash(git push * main:*)"
        "Bash(git push * HEAD:main)"
        "Bash(git push --force *)"
        "Read(~/.claude/.credentials.json)"
        "Read(~/.ssh/id_*)"
        "Read(//run/secrets/**)"
      ];
    };
  };

  managedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON managedSettingsValue
  );

  # Remote Control launchers. `repo` serves ~/repos/<name>, one git worktree per
  # session. `admin` serves ~/admin, the admin agent's home: every session runs
  # in the same directory, because the admin agent changes the box rather than
  # a checkout.
  #
  #   claude          - the flavor wrapper, which rewrites ~/.claude on launch
  #   claudeUnwrapped - the binary the wrapper execs
  #   ghToken         - path to the bot's GitHub token, exported for `gh`
  #
  # Every server launches through the same wrapper and the wrapper rewrites
  # shared files, so concurrent starts would race. The wrapper therefore runs
  # once under a lock with --version, and the server is started from the
  # unwrapped binary the wrapper would have exec'd.

  mkRemoteControl =
    {
      claude,
      claudeUnwrapped,
      ghToken,
    }:
    let
      settings = lib.toShellVars {
        claude_bin = lib.getExe claude;
        claude_unwrapped = lib.getExe claudeUnwrapped;
        gh_token_file = ghToken;
      };
      launcher =
        name: text:
        shellCheck.writeShellApplication {
          inherit name;
          runtimeInputs = [
            pkgs.jq
            pkgs.flock
          ];
          text = ''
            ${text}
            ${settings}
            ${fragment ./lock.sh}
            ${fragment ./serve.sh}
            main "$@"
          '';
        };
    in
    {
      repo = launcher "factory-rc" ''
        remote_control_args=(${lib.escapeShellArgs remoteControlArgs.repo})
        ${fragment ./ctl/paths.sh}
        ${fragment ./factory-rc.sh}
      '';

      admin = launcher "factory-rc-admin" ''
        main() {
          local dir="${adminDir}"
          mkdir -p "$dir"
          serve "$dir" admin ${lib.escapeShellArgs remoteControlArgs.admin}
        }
      '';
    };

  # factory-relink-skills <farm>, the home activation's relink. Sessions spawn
  # from a Remote Control server without going through the wrapper, so nothing
  # else moves the links off a farm factory-gc is about to collect. Skipping is
  # the safe failure: a deploy must not hang or fail over skills, and the next
  # deploy or server start links them again.
  mkRelinkSkills =
    {
      lockSeconds ? 30,
    }:
    shellCheck.writeShellApplication {
      name = "factory-relink-skills";
      runtimeInputs = [
        pkgs.flock
        (import ../skills-link { inherit pkgs; })
      ];
      text = ''
        ${fragment ./lock.sh}
        open_factory_lock
        if ! { flock --wait ${toString lockSeconds} 9 && factory-link-skills "$1"; }; then
          echo "factory-relink-skills: left ~/.claude/skills as it was" >&2
        fi
      '';
    };

  # Remote Control flags. Both start sessions in auto mode. A repository's
  # sessions each get their own git worktree, so sessions in one repository
  # never edit the same files.
  remoteControlArgs = {
    repo = [
      "--spawn"
      "worktree"
      "--capacity"
      "3"
      "--permission-mode"
      "auto"
    ];
    admin = [
      "--spawn"
      "same-dir"
      "--capacity"
      "2"
      "--permission-mode"
      "auto"
    ];
  };

  # Where the admin agent lives, and its server's unit. Shared by the launcher,
  # factory-ctl and the Home Manager module so they cannot disagree.
  adminDir = "$HOME/admin";
  adminUnit = "claude-rc-admin.service";

  # The CLI the admin agent drives the box with, and the only thing its skills
  # call. Idempotent throughout; see ctl/main.sh for the commands. systemctl,
  # gh, nix and nix-store come from PATH, like the launchers' systemctl: the unit
  # and login environments provide them, and the check substitutes doubles.
  #
  #   opsStateDir    - where the root units record their results
  #   deployRepo     - owner/repo of this flake, which deploys are requested on
  #   deployWorkflow - the workflow file that requests them
  mkCtl =
    {
      opsStateDir,
      deployRepo,
      deployWorkflow,
      gcrootsAuto ? "/nix/var/nix/gcroots/auto",
      tmpDir ? "/tmp",
    }:
    let
      settings = lib.toShellVars {
        admin_unit = adminUnit;
        deploy_repo = deployRepo;
        deploy_workflow = deployWorkflow;
        gcroots_auto = gcrootsAuto;
        ops_state_dir = opsStateDir;
        tmp_dir = tmpDir;
      };
      ctlFragments = [
        ./ctl/paths.sh
        ./ctl/lib.sh
        ./ctl/repo.sh
        ./ctl/sessions.sh
        ./space.sh
        ./ctl/status.sh
        ./ctl/disk.sh
        ./ctl/ops.sh
        ./ctl/main.sh
      ];
    in
    shellCheck.writeShellApplication {
      name = "factory-ctl";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        gawk
        gnugrep
        gnused
        git
        jq
        procps
        util-linux
      ];
      text = ''
        ${settings}
        admin_dir="${adminDir}"
        ${lib.concatMapStrings fragment ctlFragments}
      '';
    };

  # The root side of deploys: polls this host's GitHub deployments, builds the
  # pending one if its commit is the tip of main, and switches behind a health
  # gate.
  # curl, nix, nix-env, tailscale and systemctl come from the unit's PATH.
  #
  #   repo          - owner/repo of this flake
  #   host          - the nixosConfigurations attribute to build
  #   environment   - the GitHub environment deployments are created for
  #   tokenFile     - a token that may read and write this repo's deployments
  #   stateDir      - where results are recorded, readable by the agent account
  #   profile       - the system profile
  #   currentSystem - the running system
  #   healthAttempts - health checks, 5s apart, before rolling back
  mkDeploy =
    {
      repo,
      host,
      environment,
      tokenFile,
      stateDir,
      profile ? "/nix/var/nix/profiles/system",
      currentSystem ? "/run/current-system",
      healthAttempts ? 18,
    }:
    rootScript "factory-deploy"
      {
        inherit
          repo
          host
          environment
          profile
          ;
        token_file = tokenFile;
        state_dir = stateDir;
        current_system = currentSystem;
        health_attempts = healthAttempts;
      }
      [
        ./ops/state.sh
        ./ops/deploy.sh
      ];

  # rollback | reboot | gc, run as root by fixed units.
  mkMaintenance =
    {
      stateDir,
      profile ? "/nix/var/nix/profiles/system",
      gcrootsAuto ? "/nix/var/nix/gcroots/auto",
      tmpDir ? "/tmp",
      homesDir ? "/home",
    }:
    rootScript "factory-maintenance"
      {
        inherit profile;
        state_dir = stateDir;
        gcroots_auto = gcrootsAuto;
        tmp_dir = tmpDir;
        homes_dir = homesDir;
      }
      [
        ./space.sh
        ./ops/state.sh
        ./ops/maintenance.sh
      ];

  rootScript =
    name: settings: fragments:
    shellCheck.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        gnused
        jq
        util-linux
      ];
      text = ''
        ${lib.toShellVars settings}
        ${lib.concatMapStrings fragment fragments}
      '';
    };

  # Starts factory-gc when less than `gcBelowFreePercent` of / is free. Strict
  # mode here makes a failed reading a failed run rather than a silent pass; df,
  # tail and systemctl come from the unit's PATH.
  mkGcOnPressure =
    { gcBelowFreePercent }:
    shellCheck.writeShellApplication {
      name = "factory-gc-on-pressure";
      text = ''
        ${lib.toShellVars { gc_below_free_percent = gcBelowFreePercent; }}
        ${fragment ./ops/gc-on-pressure.sh}
      '';
    };

  # The admin agent's project: instructions, permissions and skills, rendered
  # into ~/admin by modules/home/factory/admin.nix. Project-scoped on purpose:
  # the flavor wrapper relinks ~/.claude/skills for every agent of this
  # account, so skills there would reach the repository agents too.
  admin = {
    instructions = ./admin/CLAUDE.md;
    settings = pkgs.writeText "admin-settings.json" (
      builtins.toJSON {
        permissions.allow = [
          "Bash(factory-ctl)"
          "Bash(factory-ctl *)"
        ];
      }
    );
    skills = lib.mapAttrs (name: _: ./admin/skills + "/${name}") (
      lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./admin/skills)
    );
  };

  # Boot: clones the declared repositories that are missing and starts every
  # enabled one.
  #
  #   repos - attrset of directory name -> clone URL
  mkBoot =
    ctl: repos:
    let
      args = lib.escapeShellArgs (
        lib.concatLists (
          lib.mapAttrsToList (name: url: [
            name
            url
          ]) repos
        )
      );
    in
    shellCheck.writeShellApplication {
      name = "factory-boot";
      text = ''
        exec ${lib.getExe ctl} boot ${args}
      '';
    };

  # nftables table that keeps the agent account (`uid`) away from everything
  # private while leaving the internet open: the tailnet, private networks and
  # the cloud metadata service. Matching the uid covers every process the
  # account runs, whether Remote Control started it or a shell did. Replies on
  # connections someone else opened pass, which keeps app previews working.
  mkEgressRules = uid: ''
    chain output {
      type filter hook output priority filter; policy accept;

      meta skuid != ${toString uid} accept
      ct state established,related accept

      # 100.64.0.0/10 - the tailnet (CGNAT range), including MagicDNS
      # 169.254.0.0/16 - link-local, including the metadata service
      ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } reject

      # fc00::/7 - unique local, including the tailnet's fd7a:115c:a1e0::/48
      ip6 daddr { fc00::/7, fe80::/10 } reject
    }
  '';
in
{
  inherit
    managedSettings
    managedSettingsValue
    remoteControlArgs
    mkRemoteControl
    mkRelinkSkills
    mkCtl
    mkBoot
    mkDeploy
    mkMaintenance
    mkGcOnPressure
    admin
    mkEgressRules
    ;
}
