# The software factory: Claude Code agents serving git repositories over Remote
# Control, from one unprivileged account. Plain functions and derivations - no
# hosts, no users, no systemd units. modules/nixos/server and
# modules/home/factory wire them in. The agents' workflow instructions
# (instructions.md) belong to the claude-factory flavor in programs/claude-code.
#
# The scripts call `systemctl` from PATH rather than bundling systemd: the
# server's units put the system profile on PATH, and it keeps them buildable -
# and testable by checks.software-factory - on every platform.
{
  pkgs,
  lib ? pkgs.lib,
}:

let
  # Remote Control flags shared by every repository's server. Each session the
  # phone opens gets its own git worktree, so two sessions in one repository
  # never edit the same files.
  remoteControlArgs = [
    "--spawn"
    "worktree"
    "--capacity"
    "2"
    "--permission-mode"
    "auto"
  ];

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

  # Runs one repository's Remote Control server. Started by the claude-rc@
  # systemd user unit with the repository's directory name.
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
    pkgs.writeShellApplication {
      name = "factory-rc";
      runtimeInputs = [
        pkgs.jq
        pkgs.flock
      ];
      text = ''
        ${repoNameCheck}

        main() {
          local name="''${1:?usage: factory-rc <repo>}"
          check_repo_name "$name"
          local dir="$HOME/repos/$name"
          [ -d "$dir/.git" ] || { echo "factory-rc: $dir is not a git repository" >&2; exit 1; }

          mkdir -p "$HOME/.claude"
          exec 9>"$HOME/.claude/.factory.lock"
          flock 9
          ${lib.getExe claude} --version >/dev/null
          trust "$dir"
          exec 9>&-

          GH_TOKEN=$(cat "${ghToken}")
          export GH_TOKEN
          cd "$dir"
          exec ${lib.getExe claudeUnwrapped} remote-control --name "$name" ${lib.escapeShellArgs remoteControlArgs}
        }

        # Remote Control refuses an untrusted directory when nobody is at a
        # terminal to confirm it, and on its first run it waits on stdin for
        # "Enable Remote Control? (y/n)" - forever, under systemd, while the
        # unit reports active. These are the records the two answers write.
        trust() {
          local config="$HOME/.claude.json" tmp
          [ -f "$config" ] || echo '{}' >"$config"
          tmp=$(mktemp "$config.XXXXXX")
          jq --arg dir "$1" '.projects[$dir].hasTrustDialogAccepted = true | .remoteDialogSeen = true' "$config" >"$tmp"
          mv "$tmp" "$config"
        }

        main "$@"
      '';
    };

  # Clones a repository into ~/repos/<name>, starts its server and pins its dev
  # shells. Idempotent: an existing clone is kept as it is.
  factoryAdd = pkgs.writeShellApplication {
    name = "factory-add";
    runtimeInputs = [
      pkgs.git
      pinShells
    ];
    text = ''
      ${repoNameCheck}

      main() {
        local url="''${1:?usage: factory-add <git-url> [name]}"
        local name="''${2:-$(repo_name_from_url "$url")}"
        check_repo_name "$name"
        local dir="$HOME/repos/$name"

        if [ -e "$dir" ]; then
          echo "factory-add: $dir already exists, keeping it."
        else
          mkdir -p "$HOME/repos"
          git clone "$url" "$dir"
        fi

        systemctl --user start "claude-rc@$name.service"
        echo "factory-add: $name is served over Remote Control."
        factory-pin-shells "$name" || echo "factory-add: pinning $name's dev shells failed" >&2
      }

      # git@github.com:owner/repo.git, https://github.com/owner/repo -> repo
      repo_name_from_url() {
        local base="''${1##*[/:]}"
        echo "''${base%.git}"
      }

      main "$@"
    '';
  };

  # Builds every dev shell of ~/repos/<name>'s flake, as checked out, and keeps
  # it as a GC root in ~/.gcroots/<name>, replacing the previous pins. Without
  # this, a shell lives only while a session uses it: the min-free collection
  # deletes it and the next session rebuilds it. A profile, as nix-direnv makes,
  # roots the shell's whole environment; `nix build` would root only the
  # shell's own near-empty output.
  #
  # `nix` comes from PATH, like `systemctl` in the other scripts, so the check
  # can stand in for it.
  pinShells = pkgs.writeShellApplication {
    name = "factory-pin-shells";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      ${repoNameCheck}

      main() {
        local name="''${1:?usage: factory-pin-shells <repo>}"
        check_repo_name "$name"
        local dir="$HOME/repos/$name" roots="$HOME/.gcroots/$name"
        [ -f "$dir/flake.nix" ] || { echo "factory-pin-shells: $name has no flake.nix, nothing to pin."; exit 0; }

        local system shells
        system=$(nix eval --raw --impure --expr builtins.currentSystem)
        shells=$(shell_names "$dir" "$system")
        rm -rf "$roots"
        mkdir -p "$roots"

        local status=0 shell
        for shell in $shells; do
          nix print-dev-env "git+file://$dir#devShells.$system.$shell" --profile "$roots/$shell" >/dev/null \
            || status=1
        done
        exit "$status"
      }

      # A flake without dev shells for this system has none to pin, not an error.
      shell_names() {
        nix eval --json --impure --expr \
          "builtins.attrNames ((builtins.getFlake \"git+file://$1\").devShells.\"$2\" or { })" \
          | jq -r '.[]'
      }

      main "$@"
    '';
  };

  # Brings every repository up at boot: clones the declared ones that are
  # missing, then starts a server for each clone in ~/repos - which includes
  # everything added by hand with factory-add - and pins each clone's dev
  # shells once every server is up. Starts are sequential, and one repository
  # that fails does not stop the rest. A shell that fails to pin is only
  # reported: the unit restarts on failure, and would rebuild it in a loop.
  #
  #   repos - attrset of directory name -> clone URL
  mkStartAll =
    repos:
    pkgs.writeShellApplication {
      name = "factory-start-all";
      runtimeInputs = [
        factoryAdd
        pinShells
      ];
      text = ''
        status=0

        ${lib.concatStrings (
          lib.mapAttrsToList (name: url: ''
            factory-add ${lib.escapeShellArg url} ${lib.escapeShellArg name} || status=1
          '') repos
        )}

        for dir in "$HOME"/repos/*/; do
          [ -d "$dir.git" ] || continue
          systemctl --user start "claude-rc@$(basename "$dir").service" || status=1
        done

        for dir in "$HOME"/repos/*/; do
          [ -d "$dir.git" ] || continue
          name=$(basename "$dir")
          factory-pin-shells "$name" || echo "factory-start-all: pinning $name's dev shells failed" >&2
        done

        exit "$status"
      '';
    };

  # A repository name becomes a directory and a systemd instance name, so it is
  # held to what is safe as both.
  repoNameCheck = ''
    check_repo_name() {
      case "$1" in
        "" | .* | *[!A-Za-z0-9._-]*)
          echo "invalid repository name '$1' (expected [A-Za-z0-9._-], not starting with '.')" >&2
          exit 1
          ;;
      esac
    }
  '';

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
    factoryAdd
    pinShells
    mkStartAll
    mkEgressRules
    ;
}
