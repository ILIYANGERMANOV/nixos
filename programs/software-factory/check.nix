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

  # Answers the two evaluations factory-pin-shells makes, and records each
  # shell it pins as a profile. A shell named `broken` fails to build.
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    echo "nix $*" >>"$CALLS"
    case "$1 $2" in
      "eval --raw") echo fake-system ;;
      "eval --json") echo "$SHELLS" ;;
      print-dev-env*)
        case "$2" in *.broken) exit 1 ;; esac
        touch "$4"
        ;;
    esac
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

  # Declares nothing, so its exit status reflects only the clones in ~/repos.
  startNone = factory.mkStartAll { };

  nftCheck = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
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
pkgs.runCommand "software-factory-check"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      factory.factoryAdd
      factory.pinShells
      remoteControl
      startAll
      (recorder "systemctl")
      fakeNix
    ];
  }
  ''
    set -euo pipefail
    work=/tmp/factory-check
    rm -rf "$work"
    mkdir -p "$work"
    export HOME="$work/home" CALLS="$work/calls" SHELLS='["ci","default"]'
    mkdir -p "$HOME"

    fail() { echo "FAIL: $*" >&2; exit 1; }
    reset() { rm -rf "$HOME/repos" "$HOME/.gcroots" "$HOME/.claude" "$HOME/.claude.json"; : >"$CALLS"; }
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
    [ "$(jq '.remoteDialogSeen' "$HOME/.claude.json")" = true ] \
      || fail "Remote Control would wait on its first-run prompt"

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

    with_flake() { mkdir -p "$HOME/repos/$1/.git"; touch "$HOME/repos/$1/flake.nix"; }

    echo "factory-pin-shells: pins every dev shell of the flake as a profile, replacing old pins"
    reset
    with_flake app
    mkdir -p "$HOME/.gcroots/app"
    touch "$HOME/.gcroots/app/stale"
    factory-pin-shells app
    for shell in ci default; do
      called "nix print-dev-env git+file://$HOME/repos/app#devShells.fake-system.$shell --profile $HOME/.gcroots/app/$shell"
      [ -e "$HOME/.gcroots/app/$shell" ] || fail "$shell was not pinned"
    done
    [ ! -e "$HOME/.gcroots/app/stale" ] || fail "a previous pin was kept"

    echo "factory-pin-shells: a repository without a flake has nothing to pin"
    reset
    mkdir -p "$HOME/repos/plain/.git"
    factory-pin-shells plain >/dev/null
    ! grep -q "^nix " "$CALLS" || fail "evaluated a repository without a flake"

    echo "factory-pin-shells: a failing shell is reported, and the others still pinned"
    reset
    with_flake app
    if SHELLS='["broken","ci"]' factory-pin-shells app; then fail "a failed shell was not reported"; fi
    [ -e "$HOME/.gcroots/app/ci" ] || fail "one failed shell stopped the others"

    echo "factory-pin-shells: rejects names unsafe as a directory"
    if factory-pin-shells ../app >/dev/null 2>&1; then fail "factory-pin-shells accepted '../app'"; fi

    echo "factory-add / factory-start-all: pin shells, and a failed pin fails neither"
    reset
    with_flake app
    SHELLS='["broken"]' factory-add "file://$work/origin.git" app >/dev/null 2>&1 \
      || fail "factory-add failed on a shell that did not pin"
    called "systemctl --user start claude-rc@app.service"
    reset
    with_flake app
    SHELLS='["broken","ci"]' ${lib.getExe startNone} >/dev/null 2>&1 || fail "factory-start-all failed on a shell that did not pin"
    called "systemctl --user start claude-rc@app.service"
    [ -e "$HOME/.gcroots/app/ci" ] || fail "factory-start-all did not pin app"

    ${nftCheck}

    echo "software-factory: all checks passed"
    touch "$out"
  ''
