# checks.software-factory: the factory's policy and scripts, exercised without
# a server. git is real (clones from a local bare repository); systemctl and
# Claude Code are doubles that record how they were called, because starting a
# unit or a Remote Control session is the behaviour under test and neither can
# run inside the build sandbox. On Linux the egress rules also go through
# `nft --check`, the same validation NixOS runs when it builds the host.
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
    ghToken = "/tmp/factory-check/gh-token";
  };

  startAll = factory.mkStartAll {
    declared = "file:///tmp/factory-check/origin.git";
    unreachable = "file:///tmp/factory-check/missing.git";
  };

  nftCheck = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    echo "nft --check: egress rules"
    cat >ruleset.conf <<'EOF'
    table inet factory-egress {
    ${factory.mkEgressRules 1000}
    }
    EOF
    LD_PRELOAD="${pkgs.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
      ${pkgs.nftables}/bin/nft --check --file ruleset.conf
  '';
in
assert lib.assertMsg (failedPolicy == [ ]) (
  "software-factory managed settings: " + lib.concatMapStringsSep "; " (a: a.msg) failedPolicy
);
pkgs.runCommand "software-factory-check"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      factory.factoryAdd
      remoteControl
      startAll
      (recorder "systemctl")
    ];
  }
  ''
    set -euo pipefail
    work=/tmp/factory-check
    rm -rf "$work"
    mkdir -p "$work"
    export HOME="$work/home" CALLS="$work/calls"
    mkdir -p "$HOME"

    fail() { echo "FAIL: $*" >&2; exit 1; }
    reset() { rm -rf "$HOME/repos" "$HOME/.claude" "$HOME/.claude.json"; : >"$CALLS"; }
    called() { grep -qxF "$1" "$CALLS" || { cat "$CALLS" >&2; fail "expected call: $1"; }; }

    git init --quiet --bare "$work/origin.git"

    echo "factory-add: clones under the name in an ssh URL and starts its server"
    reset
    factory-add "file://$work/origin.git" >/dev/null 2>&1
    [ -d "$HOME/repos/origin/.git" ] || fail "origin was not cloned"
    called "systemctl --user start claude-rc@origin.service"

    echo "factory-add: derives the name from ssh and https URLs"
    reset
    mkdir -p "$HOME/repos/repo" "$HOME/repos/other"
    factory-add git@github.com:owner/repo.git >/dev/null
    factory-add https://github.com/owner/other >/dev/null
    called "systemctl --user start claude-rc@repo.service"
    called "systemctl --user start claude-rc@other.service"

    echo "factory-add: an explicit name wins, and an existing clone is kept"
    reset
    mkdir -p "$HOME/repos/custom"
    touch "$HOME/repos/custom/marker"
    factory-add "file://$work/origin.git" custom >/dev/null
    [ -e "$HOME/repos/custom/marker" ] || fail "existing clone was replaced"
    called "systemctl --user start claude-rc@custom.service"

    echo "factory-add / factory-rc: reject names unsafe as a directory or unit"
    for bad in ".hidden" ".." "a b" "a/b" 'a$b'; do
      reset
      if factory-add "file://$work/origin.git" "$bad" >/dev/null 2>&1; then
        fail "factory-add accepted '$bad'"
      fi
      [ ! -s "$CALLS" ] || fail "factory-add started a unit for '$bad'"
      if factory-rc "$bad" >/dev/null 2>&1; then
        fail "factory-rc accepted '$bad'"
      fi
    done
    if factory-rc "" >/dev/null 2>&1; then fail "factory-rc accepted an empty name"; fi
    if factory-add "file://$work/.git" >/dev/null 2>&1; then
      fail "factory-add accepted a URL whose name starts with '.'"
    fi

    echo "factory-rc: applies the flavor, trusts the repo, starts Remote Control"
    reset
    git clone --quiet "$work/origin.git" "$HOME/repos/origin" 2>/dev/null
    echo '{"projects":{"/elsewhere":{"hasTrustDialogAccepted":true}}}' >"$HOME/.claude.json"
    printf 'ghp_check' >"$work/gh-token"
    factory-rc origin
    called "claude-factory --version"
    called "claude remote-control --name origin ${lib.escapeShellArgs factory.remoteControlArgs} GH_TOKEN=ghp_check PWD=$HOME/repos/origin"
    [ "$(jq '.projects["'"$HOME/repos/origin"'"].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] \
      || fail "repo was not trusted"
    [ "$(jq '.projects["/elsewhere"].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] \
      || fail "trusting one repo lost another's trust"

    echo "factory-rc: refuses a directory that is not a clone"
    reset
    mkdir -p "$HOME/repos/plain"
    if factory-rc plain >/dev/null 2>&1; then fail "factory-rc served a non-repository"; fi
    [ ! -s "$CALLS" ] || fail "factory-rc ran Claude for a non-repository"

    echo "factory-start-all: clones declared repos, starts every clone, survives a failure"
    reset
    git clone --quiet "$work/origin.git" "$HOME/repos/by-hand" 2>/dev/null
    if factory-start-all >/dev/null 2>&1; then fail "a failed clone was not reported"; fi
    [ -d "$HOME/repos/declared/.git" ] || fail "declared repo was not cloned"
    called "systemctl --user start claude-rc@declared.service"
    called "systemctl --user start claude-rc@by-hand.service"
    ! grep -q "claude-rc@unreachable" "$CALLS" || fail "started a repo that failed to clone"

    ${nftCheck}

    echo "software-factory: all checks passed"
    touch "$out"
  ''
