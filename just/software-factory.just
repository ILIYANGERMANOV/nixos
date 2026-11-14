# ─── Software factory ────────────────────────────────────────────────────────
# Recipes for the software factories (`factories` in flake.nix). The order of a
# first install is in docs/SOFTWARE-FACTORY.md. Each recipe's doc line starts
# with where it runs: [mac] is a terminal on macos-main in this repository.
#
# Every factory recipe takes the factory's hostname first, and fails on a name
# that is not a factory before doing anything (just/scripts/factory-host.sh).
#
# Hosts are reached by their MagicDNS name, so these need Tailscale up on this
# Mac (`just macos-main-tailscale-up`), except factory-install, which talks to
# the fresh machine's own address.
#
# Parameters are declared as `$name`: just passes them as environment variables
# instead of splicing them into the script text, so a hostile argument is inert.
# Secrets are read with `read -s` and travel on stdin, never in argv, where any
# local process could read them from the process list.

# ─── Secrets ─────────────────────────────────────────────────────────────────

# Nothing is written to disk: age-keygen prints the key to a shell variable,
# which goes to the clipboard for Bitwarden and is then cleared. Only the public
# half is kept, in .sops.yaml, in place of the host's marker line. To install
# the key on a new machine, factory-install asks for it back from Bitwarden.
#
# [mac] Generate <host>'s age key into the clipboard (for Bitwarden)
factory-generate-age-key $host:
    @bash "{{ justfile_directory() }}/just/scripts/factory-generate-age-key.sh" "$host"

# Fills secrets/hosts/<host>.yaml with everything the host declares, creating
# it from its .sops.yaml rule when it is missing: the admin password (reusing
# set-password-hash), the Tailscale auth key, the bot's GitHub token, the probe
# modules/secrets.nix requires, the deploy token, and a ThinkPad's Wi-Fi.
#
# [mac] Write every secret <host> needs into its sops file
factory-secrets $host:
    @bash "{{ justfile_directory() }}/just/scripts/factory-secrets.sh" "$host"

# The server pulls deploys from this repository's GitHub deployments and posts
# the result back, with a fine-grained token of the repository owner: this
# repository only, Deployments read and write, nothing else. It is root-only on
# the server, unlike the bot's token. Steps in docs/SOFTWARE-FACTORY.md, step 9.
#
# [mac] Write or renew <host>'s deploy token in its sops file
factory-deploy-token $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    file="secrets/hosts/$host.yaml"

    sudo -v

    echo "Your account (not the bot's) > Settings > Developer settings > Fine-grained tokens:"
    echo "only this nixos repository, permission Deployments: Read and write."
    read -rsp "Deploy token: " value; echo
    case "$value" in
        github_pat_*) ;;
        *) echo "ERROR: expected a fine-grained token (github_pat_...)." >&2; exit 1 ;;
    esac
    printf '%s' "$value" | just _sops-set-string "$host" factory-deploy-token
    echo "Wrote factory-deploy-token. Commit $file (just factory-secrets-commit $host), then deploy."

# The network a ThinkPad factory joins (modules/nixos/server/platforms/
# thinkpad-t15p.nix): an EnvironmentFile for NetworkManager, so each value is
# double-quoted with systemd's escapes. Neither is echoed: the network name
# says where the box is. A backslash still reaches NetworkManager's keyfile,
# which reads it as an escape: such a password is not supported.
#
# [mac] Write or change <host>'s Wi-Fi network in its sops file
factory-wifi $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    file="secrets/hosts/$host.yaml"

    sudo -v

    read -rsp "Wi-Fi network name (SSID): " ssid; echo
    read -rsp "Wi-Fi password: " psk; echo
    [ -n "$ssid" ] && [ -n "$psk" ] || { echo "ERROR: empty network name or password." >&2; exit 1; }
    escape() { sed -e 's/[\\"$`]/\\&/g'; }
    ssid=$(printf '%s' "$ssid" | escape)
    psk=$(printf '%s' "$psk" | escape)
    printf 'WIFI_SSID="%s"\nWIFI_PSK="%s"\n' "$ssid" "$psk" | just _sops-set-string "$host" wifi-env
    unset ssid psk
    echo "Wrote wifi-env. Commit $file (just factory-secrets-commit $host), then deploy."

# Commits only .sops.yaml and the host's secrets file, whatever else is staged,
# and pushes the current branch: the flake sees the file only once git tracks
# it, and CI only once it is pushed.
#
# [mac] Commit and push <host>'s secrets on the current branch
factory-secrets-commit $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    file="secrets/hosts/$host.yaml"
    git add .sops.yaml "$file"
    git commit -m "[factory] $host: secrets" -- .sops.yaml "$file"
    git push -u origin HEAD

# The key is pasted from Bitwarden into a shell variable and goes to the server
# on stdin. It sits briefly in admin's home (mode 600) because sudo needs the
# terminal for its password, so the same connection cannot also carry the key.
#
# [mac] Restore <host>'s age key from Bitwarden onto the running server
factory-restore-age-key $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Paste '$host-age-key' from Bitwarden, then press Ctrl-D on a new line:"
    key=$(cat)
    printf '%s\n' "$key" | grep -q '^AGE-SECRET-KEY-1' || {
        echo "ERROR: does not look like an age private key." >&2
        exit 1
    }
    printf '%s\n' "$key" | ssh -p 2222 "admin@$host" 'umask 077; cat > ~/.age-key.tmp'
    unset key
    ssh -t -p 2222 "admin@$host" \
        'sudo install -D -m 600 -o root -g root ~/.age-key.tmp /var/lib/sops-age/keys.txt; rm -f ~/.age-key.tmp'
    echo "Key restored. Deploy again (just factory-deploy $host) to decrypt with it."

# ─── Install and deploy ──────────────────────────────────────────────────────

# For a Hetzner server whose console refuses the YubiKey's key format: a
# passwordless key for the first root login only, added to this Mac's agent so
# factory-install offers it. Paste the printed public half into Hetzner.
#
# [mac] Create a throwaway SSH key for <host>'s install and print its public half
factory-install-key $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    key="/tmp/$host-install"
    test -e "$key" || ssh-keygen -q -t ed25519 -N "" -C "$host-install" -f "$key"
    ssh-add "$key"
    cat "$key.pub"

# Removes the throwaway key from this Mac; delete it from Hetzner's Security >
# SSH keys by hand.
#
# [mac] Delete the throwaway install key of <host> from this Mac
factory-install-key-remove $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    key="/tmp/$host-install"
    ssh-add -d "$key.pub" 2>/dev/null || true
    rm -f "$key" "$key.pub"
    echo "Removed $key. Delete it from Hetzner (Security > SSH keys) too."

# Replaces whatever runs on the target with NixOS, using nixos-anywhere over
# root SSH: a fresh Hetzner server (Ubuntu image or rescue system), or a
# ThinkPad booted from the NixOS minimal ISO with a root password set. Details
# in just/scripts/factory-install.sh.
#
# [mac] Install NixOS on <host> at <ip> (wipes its disk)
factory-install $host $ip:
    @bash "{{ justfile_directory() }}/just/scripts/factory-install.sh" "$host" "$ip"

# Both ways in after an install: admin on port 2222 with the YubiKey, and the
# agent account over Tailscale SSH. Each accepts a new host key once.
#
# [mac] Check that admin and factory can both log in to <host>
factory-ssh-check $host: (_factory-host host) macos-main-tailscale-up
    ssh -p 2222 "admin@$host" true
    @echo "admin@$host: ok"
    ssh "factory@$host" true
    @echo "factory@$host: ok"

# Deploys the working tree as it is, committed or not. The flake and its inputs
# are copied to the server's store - content-addressed paths, which need no
# trusted user - and the server builds and switches to it. sudo asks for the
# admin password on the terminal.
#
# [mac] Build and switch <host> to this working tree
factory-deploy $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    export NIX_SSHOPTS="-p 2222"
    source=$(nix flake metadata --json | nix run --inputs-from . nixpkgs#jq -- -r .path)
    nix flake archive --to "ssh-ng://admin@$host"
    ssh -t -p 2222 "admin@$host" \
        sudo nixos-rebuild switch --flake "$source#$host"

# When GitHub or the deploy path itself is broken: Tailscale up, the cache guard
# on this host's closure (it fails if this nixpkgs rev would compile something
# expensive), then factory-deploy.
#
# [mac] Deploy this working tree to <host> without GitHub
factory-break-glass $host: (_factory-host host) macos-main-tailscale-up (_cache-check "factory-break-glass" (".#nixosConfigurations." + host + ".config.system.build.toplevel")) (factory-deploy host)

# Read-only. Runs as the agent account over Tailscale SSH, so it needs no
# YubiKey touch and cannot read the system journal; everything it shows is
# visible to that account. The script travels on stdin, so nothing on the
# server has to be deployed for it to change.
#
# [mac] Show <host>'s RAM, disk and Remote Control sessions (`detailed` adds branches, errors, top processes)
factory-status $host $mode="concise":
    @bash "{{ justfile_directory() }}/just/scripts/factory-status.sh" "$host" "$mode"

# ─── On the factory ──────────────────────────────────────────────────────────

# Generates the bot's SSH key on the server, as the agent account, so the
# private half never exists anywhere else. Idempotent: an existing key is kept.
#
# [mac] Create the bot's SSH key on <host> and print its public half
factory-gh-key $host: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    # shellcheck disable=SC2029 # $host is a factory's name and names the key
    ssh "factory@$host" \
        "test -e ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -C $host -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub"
    echo ""
    echo "Add this key to the bot account TWICE: as an Authentication key and as a"
    echo "Signing key (GitHub > Settings > SSH and GPG keys)."

# Claude Code's first-run login, interactive, as the agent account. Once you
# /exit, every repository's Remote Control server restarts with the login and
# the running ones are listed.
#
# [mac] Log in to Claude on <host>, then start its repositories' servers
factory-claude-login $host: (_factory-host host)
    ssh -t "factory@$host" claude-factory
    ssh "factory@$host" "systemctl --user restart factory-repos && systemctl --user list-units 'claude-rc@*'"

# Stops the repository's server for good (factory-ctl stop, which refuses while
# sessions are live) and deletes its clone with every worktree in it, after you
# type its name again. Unpushed work in it is lost.
#
# [mac] Stop <repo> on <host> and delete its clone
factory-remove-repo $host $repo: (_factory-host host)
    #!/usr/bin/env bash
    set -euo pipefail
    case "$repo" in
        "" | . | .. | -* | *[!A-Za-z0-9._-]*) echo "ERROR: invalid repository name '$repo'" >&2; exit 1 ;;
        *) ;;
    esac
    read -rp "Delete ~/repos/$repo on $host, with any unpushed work? Type its name: " answer
    [ "$answer" = "$repo" ] || { echo "Not deleted." >&2; exit 1; }
    # shellcheck disable=SC2029 # $repo is checked above and meant for the remote side
    ssh "factory@$host" "factory-ctl stop $repo && rm -rf ~/repos/$repo"
    echo "Removed $repo from $host."

# For a server that is up but wedged: it restarts on its own after a crash.
#
# [mac] Restart <host>'s admin Remote Control server
factory-restart-admin $host: (_factory-host host)
    ssh "factory@$host" systemctl --user restart claude-rc-admin

# Fails, naming the factories, unless $host is one; see factory-host.sh.
[private]
_factory-host $host:
    @bash "{{ justfile_directory() }}/just/scripts/factory-host.sh" "$host" >/dev/null

# Writes stdin to secret $name in $host's sops file, as one JSON string: the
# value form `sops set` takes. The caller runs `sudo -v` first, while it still
# has the terminal: sops reads the age key with `sudo -n`.
[private]
_sops-set-string $host $name:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v jq >/dev/null 2>&1; then
        jq_cmd=(jq)
    else
        jq_cmd=(nix run --inputs-from . nixpkgs#jq --)
    fi
    "${jq_cmd[@]}" -Rs . |
        SOPS_AGE_KEY_CMD="sudo -n cat /var/lib/sops-age/keys.txt" \
        sops set --value-stdin "secrets/hosts/$host.yaml" "[\"$name\"]"

# ─── GitHub and Tailscale ────────────────────────────────────────────────────

# REPLACES the tailnet policy with tailscale/policy.hujson, after the API has
# validated it. The API key is pasted (read -s) and reaches curl on stdin, never
# in argv. Use a short-lived key and revoke it afterwards.
#
# [mac] Validate and apply tailscale/policy.hujson to the tailnet
tailscale-apply:
    #!/usr/bin/env bash
    set -euo pipefail
    read -rsp "Tailscale API access token: " token; echo
    [ -n "$token" ] || { echo "ERROR: empty token." >&2; exit 1; }

    api() {
        printf 'user = "%s:"\n' "$token" | curl --fail-with-body -sS -K - \
            -H "Content-Type: application/hujson" \
            --data-binary @tailscale/policy.hujson \
            "https://api.tailscale.com/api/v2/tailnet/-/acl$1"
    }

    echo "Validating..."
    result=$(api /validate)
    if [ -n "$result" ] && [ "$result" != "{}" ]; then
        echo "ERROR: the policy did not validate:" >&2
        echo "$result" >&2
        exit 1
    fi
    api "" >/dev/null
    echo "Applied tailscale/policy.hujson."

# ─── macos-main ──────────────────────────────────────────────────────────────

# [mac] Connect macos-main to the tailnet (reach the factories and their previews)
macos-main-tailscale-up:
    /Applications/Tailscale.app/Contents/MacOS/Tailscale up

# [mac] Disconnect macos-main from the tailnet
macos-main-tailscale-down:
    /Applications/Tailscale.app/Contents/MacOS/Tailscale down
