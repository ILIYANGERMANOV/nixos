# checks.shell-tests: the factory's policy, scripts and admin skills, exercised
# without a server by the bats suites beside them (`ctl/disk.bats` tests
# `ctl/disk.sh`, `test_helper.bash` is what they share). git, process lookup and
# the filesystem are real: repositories are cloned from a local bare repository,
# and sessions are real processes. What cannot run in the build sandbox is a
# double - an in-memory systemd, GitHub's API and CLI, Nix's build and profile
# commands, Tailscale - and each records how it was called.
# On Linux the egress rules also go through `nft --check`, the same validation
# NixOS runs when it builds the host.
{
  pkgs,
  lib ? pkgs.lib,
}:

let
  factory = import ./. { inherit pkgs lib; };

  policy = factory.managedSettingsValue;
  policyAssertions = [
    {
      ok = policy.forceLoginMethod == "claudeai";
      msg = "forceLoginMethod must be claudeai, or an API key could bill the API";
    }
    {
      ok = policy.allowedProviders == [ "anthropic" ];
      msg = "allowedProviders must be exactly [ anthropic ]";
    }
    {
      ok = policy.permissions.disableBypassPermissionsMode == "disable";
      msg = "bypassPermissions must be disabled";
    }
    {
      ok = policy.permissions.defaultMode == "auto";
      msg = "sessions must start in auto mode";
    }
  ];
  failedPolicy = lib.filter (a: !a.ok) policyAssertions;

  work = "/tmp/factory-check";
  gcrootsAuto = "${work}/gcroots/auto";
  tmpDir = "${work}/tmp";

  # Records every call as one line: the program name, then its arguments.
  recorder =
    name:
    pkgs.writeShellScriptBin name ''
      echo "${name} $*" >>"$CALLS"
    '';

  fakeClaude = recorder "claude-factory";
  fakeClaudeUnwrapped = pkgs.writeShellScriptBin "claude" ''
    echo "claude $* GH_TOKEN=$GH_TOKEN PWD=$PWD" >>"$CALLS"
  '';

  remoteControl = factory.mkRemoteControl {
    claude = fakeClaude;
    claudeUnwrapped = fakeClaudeUnwrapped;
    ghToken = "${work}/gh-token";
  };

  relinkSkills = factory.mkRelinkSkills { lockSeconds = 1; };

  ctl = factory.mkCtl {
    opsStateDir = "${work}/ops";
    deployRepo = "owner/nixos";
    deployWorkflow = "deploy-factory.yml";
    inherit gcrootsAuto tmpDir;
  };

  boot = factory.mkBoot ctl {
    declared = "file://${work}/origin.git";
    unreachable = "file://${work}/missing.git";
  };

  deploy = factory.mkDeploy {
    repo = "owner/nixos";
    host = "software-factory";
    environment = "software-factory";
    tokenFile = "${work}/deploy-token";
    stateDir = "${work}/ops";
    profile = "${work}/profiles/system";
    currentSystem = "${work}/current-system";
    healthAttempts = 2;
  };

  maintenance = factory.mkMaintenance {
    stateDir = "${work}/ops";
    profile = "${work}/profiles/system";
    inherit gcrootsAuto tmpDir;
    # $HOME is ${work}/home.
    homesDir = work;
  };

  # An in-memory systemd: a unit is active while a file named after it exists.
  # Answers `is-active --quiet` for the deploy's health gate from $SSHD_UP.
  fakeSystemctl = pkgs.writeShellScriptBin "systemctl" (builtins.readFile ./fakes/systemctl.sh);

  # GitHub's CLI, for `resolve` and `deploy`. Repositories come from
  # $GH/user-repos.json; a dispatched workflow run gets id 42, and it fails
  # when $GH/run-fails exists.
  fakeGh = pkgs.writeShellScriptBin "gh" (builtins.readFile ./fakes/gh.sh);

  # GitHub's REST API for the deploy script. GETs are answered from files in
  # $GH named after the endpoint; POST bodies are appended to $GH/posted. The
  # curl config arrives on stdin and is kept in $GH/config, apart from argv.
  fakeCurl = pkgs.writeShellScriptBin "curl" (builtins.readFile ./fakes/curl.sh);

  fakeNix = pkgs.writeShellScriptBin "nix" (builtins.readFile ./fakes/nix.sh);

  # Profiles are symlinks in ${work}/profiles, as Nix keeps them.
  fakeNixEnv = pkgs.writeShellScriptBin "nix-env" ''
    echo "nix-env $*" >>"$CALLS"
    case "$3" in
      --set) ln -sfn "$4" "$2" ;;
      --rollback) ln -sfn "${work}/systems/old" "$2" ;;
    esac
  '';

  fakeNixStore = pkgs.writeShellScriptBin "nix-store" ''
    echo "nix-store $*" >>"$CALLS"
    [ "$2" != --print-dead ] || echo "$HOME/garbage"
    [ "$1" != --realise ] || ln -sfn "$4" "$3"
  '';

  fakeTailscale = pkgs.writeShellScriptBin "tailscale" ''
    echo '{"BackendState": "Running"}'
  '';

  suites = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./test_helper.bash
      (lib.fileset.fileFilter (file: file.hasExt "bats") ./.)
    ];
  };

  skillsCheck = (import ../agents { inherit pkgs lib; }).skills.mkCheck factory.admin.skills;

  nftCheck = ''
    echo "nft --check: egress rules"
    cat >ruleset.conf <<'EOF'
    table inet factory-egress {
    ${factory.mkEgressRules 1000}
    }
    EOF
    # The same invocation NixOS uses for networking.nftables.checkRuleset:
    # an in-process kernel (lkl), with /etc lookups redirected into the store.
    export NIX_REDIRECTS=/etc/protocols=${pkgs.iana-etc}/etc/protocols:/etc/services=${pkgs.iana-etc}/etc/services
    LD_PRELOAD="${pkgs.libredirect}/lib/libredirect.so ${pkgs.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
      ${pkgs.nftables}/bin/nft --check --file ruleset.conf
  '';
in
assert lib.assertMsg (failedPolicy == [ ]) (
  "software-factory managed settings: " + lib.concatMapStringsSep "; " (a: a.msg) failedPolicy
);
pkgs.runCommand "shell-tests"
  {
    nativeBuildInputs = [
      pkgs.bats
      pkgs.git
      pkgs.jq
      pkgs.procps
      pkgs.flock
      remoteControl.repo
      remoteControl.admin
      relinkSkills
      (import ../skills-link { inherit pkgs; })
      ctl
      boot
      deploy
      maintenance
      fakeSystemctl
      fakeGh
      fakeCurl
      fakeNix
      fakeNixEnv
      fakeNixStore
      fakeTailscale
    ];
    inherit work;
    repoArgs = lib.escapeShellArgs factory.remoteControlArgs.repo;
    adminArgs = lib.escapeShellArgs factory.remoteControlArgs.admin;
    adminSettings = factory.admin.settings;
  }
  ''
    set -euo pipefail
    # Admin skills: frontmatter, names and description length.
    echo "admin skills: ${skillsCheck}"

    # One at a time: the programs have $work baked in.
    bats --recursive --formatter tap ${suites}

    ${nftCheck}

    echo "shell-tests: all checks passed"
    touch "$out"
  ''
