# ─── Software factory ────────────────────────────────────────────────────────
# Recipes for the software-factory server, run from macos-main. The order of a
# first install is in docs/SOFTWARE-FACTORY.md.
#
# Hosts are reached by their MagicDNS name, so these need Tailscale up on this
# Mac (`just macos-main-tailscale-up`), except factory-install, which talks to
# the fresh server's public address over the internet.
#
# Parameters are declared as `$name`: just passes them as environment variables
# instead of splicing them into the script text, so a hostile argument is inert.
# Secrets are read with `read -s` and travel on stdin, never in argv, where any
# local process could read them from the process list.

# ─── Secrets ─────────────────────────────────────────────────────────────────

# Nothing is written to disk: age-keygen prints the key to a shell variable,
# which goes to the clipboard for Bitwarden and is then cleared. Only the public
# half is kept, in .sops.yaml. To install the key on a new server,
# factory-install asks for it back from Bitwarden.
#
# Generate the software-factory age key into the clipboard (for Bitwarden)
factory-generate-age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    marker='# software-factory-age-key: not generated yet'
    grep -qF "$marker" .sops.yaml || {
        echo "ERROR: .sops.yaml already lists a software-factory key." >&2
        echo "A new key cannot decrypt secrets/hosts/software-factory.yaml; to rotate," >&2
        echo "put the marker line back by hand and re-encrypt with 'sops updatekeys'." >&2
        exit 1
    }

    if command -v age-keygen >/dev/null 2>&1; then
        age_keygen=(age-keygen)
    else
        age_keygen=(nix shell --inputs-from . nixpkgs#age -c age-keygen)
    fi

    key=$("${age_keygen[@]}" 2>/dev/null)
    public=$(printf '%s\n' "$key" | sed -n 's/^# public key: //p')
    [ -n "$public" ] || { echo "ERROR: age-keygen produced no public key." >&2; exit 1; }

    printf '%s\n' "$key" | pbcopy
    unset key
    echo "The private key is on the clipboard. Save it in Bitwarden as"
    echo "'software-factory-age-key' (the whole text, both lines)."
    read -rsp "Press Enter once saved - the clipboard is cleared in 120s either way. " -t 120 || true
    echo
    pbcopy </dev/null
    echo "Clipboard cleared."

    sed -i '' "s|$marker|- $public # software-factory|" .sops.yaml
    echo "Added $public to .sops.yaml."
    echo "Next: just factory-secrets"

# Fills secrets/hosts/software-factory.yaml with everything the host declares:
# the admin password (reusing set-password-hash), the Tailscale auth key, the
# bot's GitHub token, and the probe modules/secrets.nix requires.
#
# Write every secret software-factory needs into its sops file
factory-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    file=secrets/hosts/software-factory.yaml
    key_file=/var/lib/sops-age/keys.txt

    if grep -qF '# software-factory-age-key: not generated yet' .sops.yaml; then
        echo "ERROR: run 'just factory-generate-age-key' first, or the server" >&2
        echo "could not decrypt its own secrets." >&2
        exit 1
    fi

    just set-password-hash software-factory

    sudo -v
    export SOPS_AGE_KEY_CMD="sudo -n cat $key_file"

    if command -v jq >/dev/null 2>&1; then
        jq_cmd=(jq)
    else
        jq_cmd=(nix run --inputs-from . nixpkgs#jq --)
    fi

    # sops wants the value as JSON; jq -R quotes and escapes it.
    set_secret() {
        local name="$1" prompt="$2" value
        read -rsp "$prompt: " value; echo
        [ -n "$value" ] || { echo "ERROR: $name is empty." >&2; exit 1; }
        printf '%s' "$value" | "${jq_cmd[@]}" -R . | sops set --value-stdin "$file" "[\"$name\"]"
        echo "Wrote $name."
    }

    echo "Tailscale admin console > Settings > Keys: a one-off, pre-approved auth key"
    echo "tagged tag:factory. Apply tailscale/policy.hujson first (just tailscale-apply)."
    set_secret tailscale-authkey "Tailscale auth key"

    echo "Bot account > Settings > Developer settings > Tokens (classic): scope 'repo' only."
    set_secret gh-token "Bot GitHub token"

    printf '"%s"' "unused" | sops set --value-stdin "$file" '["example-global"]'
    echo "Done. Commit .sops.yaml and $file."

# The key is pasted from Bitwarden into a shell variable and goes to the server
# on stdin. It sits briefly in admin's home (mode 600) because sudo needs the
# terminal for its password, so the same connection cannot also carry the key.
#
# Restore the software-factory age key from Bitwarden onto the running server
factory-restore-age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Paste 'software-factory-age-key' from Bitwarden, then press Ctrl-D on a new line:"
    key=$(cat)
    printf '%s\n' "$key" | grep -q '^AGE-SECRET-KEY-1' || {
        echo "ERROR: does not look like an age private key." >&2
        exit 1
    }
    printf '%s\n' "$key" | ssh -p 2222 admin@software-factory 'umask 077; cat > ~/.age-key.tmp'
    unset key
    ssh -t -p 2222 admin@software-factory \
        'sudo install -D -m 600 -o root -g root ~/.age-key.tmp /var/lib/sops-age/keys.txt; rm -f ~/.age-key.tmp'
    echo "Key restored. Deploy again (just factory-deploy) to decrypt with it."

# ─── Install and deploy ──────────────────────────────────────────────────────

# Replaces whatever runs on a fresh Hetzner server (the stock Ubuntu image, or
# the rescue system) with NixOS, using nixos-anywhere over root SSH. The age key
# is pasted from Bitwarden into a private temp directory that nixos-anywhere
# copies to the new root, and the directory is removed on exit. The system is
# built on the server: this Mac cannot build x86_64-linux.
#
# Install NixOS on a fresh Hetzner server (wipes its disk)
factory-install $ip:
    #!/usr/bin/env bash
    set -euo pipefail
    case "$ip" in
        *[!0-9.]* | "") echo "ERROR: expected an IPv4 address, got '$ip'" >&2; exit 1 ;;
    esac

    extra=$(mktemp -d)
    trap 'rm -rf "$extra"' EXIT
    install -d -m 700 "$extra/var/lib/sops-age"

    echo "Paste 'software-factory-age-key' from Bitwarden, then press Ctrl-D on a new line:"
    (umask 077; cat > "$extra/var/lib/sops-age/keys.txt")
    grep -q '^AGE-SECRET-KEY-1' "$extra/var/lib/sops-age/keys.txt" || {
        echo "ERROR: does not look like an age private key." >&2
        exit 1
    }

    nix run --inputs-from . nixpkgs#nixos-anywhere -- \
        --flake .#software-factory \
        --build-on remote \
        --extra-files "$extra" \
        --target-host "root@$ip"

    echo "Installed. Remove the temporary inbound SSH rule from the Hetzner firewall now."

# Deploys the working tree as it is, committed or not. The flake and its inputs
# are copied to the server's store - content-addressed paths, which need no
# trusted user - and the server builds and switches to it. sudo asks for the
# admin password on the terminal.
#
# Build and switch software-factory to this working tree
factory-deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    export NIX_SSHOPTS="-p 2222"
    source=$(nix flake metadata --json | nix run --inputs-from . nixpkgs#jq -- -r .path)
    nix flake archive --to ssh-ng://admin@software-factory
    ssh -t -p 2222 admin@software-factory \
        sudo nixos-rebuild switch --flake "$source#software-factory"

# Read-only. Runs as the agent account over Tailscale SSH, so it needs no
# YubiKey touch and cannot read the system journal; everything it shows is
# visible to that account. The script travels on stdin, so nothing on the
# server has to be deployed for it to change.
#
# Show software-factory's RAM and disk use, Remote Control servers and sessions
factory-status:
    #!/usr/bin/env bash
    set -euo pipefail
    # The remote side runs without -e or pipefail, so one failing section
    # still leaves the others printed.
    ssh -o ConnectTimeout=10 factory@software-factory 'bash -s' <<'EOF' || {
    set -u

    main() {
      usage
      section "Remote Control";  remote_control
      section "Recent branches"; branches
      section "Problems";        problems
      section "Top memory";      top_memory
    }

    section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

    # "Used" RAM is what cannot be reclaimed: total minus available, so page
    # cache does not count.
    usage() {
      local ram disk
      ram=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%d%%", (t - a) * 100 / t }' /proc/meminfo)
      disk=$(df --output=pcent / | tail -n 1 | tr -d ' ')
      printf '\033[1mRAM %s used  ·  Disk %s used\033[0m\n' "$ram" "$disk"
    }

    # A session is a `claude --print --sdk-url` process; its working directory
    # is a worktree under the repository it serves.
    remote_control() {
      local unit repo state sessions
      for unit in $(systemctl --user list-units 'claude-rc@*' --all --no-legend --plain | awk '{print $1}'); do
        repo=${unit#claude-rc@}; repo=${repo%.service}
        state=$(systemctl --user is-active "$unit")
        sessions=$(session_count "$repo")
        printf '%-20s %-10s %s session(s)\n' "$repo" "$state" "$sessions"
      done
    }

    session_count() {
      local pid count=0
      for pid in $(pgrep -u "$(id -u)" -f -- '--sdk-url'); do
        case "$(readlink "/proc/$pid/cwd" 2>/dev/null)" in
          "$HOME/repos/$1" | "$HOME/repos/$1"/*) count=$((count + 1)) ;;
        esac
      done
      echo "$count"
    }

    branches() {
      local dir
      for dir in "$HOME"/repos/*/; do
        printf '%s\n' "$(basename "$dir")"
        git -C "$dir" for-each-ref --sort=-committerdate --count=3 \
          --format='  %(committerdate:relative)  %(refname:short)  %(subject)' refs/heads
      done
    }

    # Failed user units, and Remote Control errors from the last hour.
    problems() {
      local found
      found=$(
        systemctl --user --failed --no-legend --plain
        journalctl --user --unit='claude-rc@*' --since -1h --no-pager -o short -q \
          | grep -aiE 'error|fatal|denied|killed' | tail -n 10
      )
      printf '%s\n' "${found:-none}"
    }

    top_memory() {
      ps -eo rss=,args= --sort=-rss | head -n 8 | awk '{ printf "%7.0fM  %s\n", $1 / 1024, substr($0, index($0, $2), 100) }'
    }

    main
    EOF
        status=$?
        [ "$status" -ne 255 ] || echo "ERROR: could not reach software-factory. Is Tailscale up? (just macos-main-tailscale-up)" >&2
        exit "$status"
    }

# Fail if rebuilding software-factory would build anything on the expensive-builds denylist.
factory-cache-check: (_cache-check "factory-cache-check" ".#nixosConfigurations.software-factory.config.system.build.toplevel")

# ─── GitHub and Tailscale ────────────────────────────────────────────────────

# Generates the bot's SSH key on the server, as the agent account, so the
# private half never exists anywhere else. Idempotent: an existing key is kept.
#
# Create the bot's SSH key on software-factory and print its public half
factory-gh-key:
    ssh factory@software-factory \
        'test -e ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N "" -C software-factory -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub'
    @echo ""
    @echo "Add this key to the bot account TWICE: as an Authentication key and as a"
    @echo "Signing key (GitHub > Settings > SSH and GPG keys)."

# REPLACES the tailnet policy with tailscale/policy.hujson, after the API has
# validated it. The API key is pasted (read -s) and reaches curl on stdin, never
# in argv. Use a short-lived key and revoke it afterwards.
#
# Validate and apply tailscale/policy.hujson to the tailnet
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

# Connect macos-main to the tailnet (reach software-factory and its previews)
macos-main-tailscale-up:
    /Applications/Tailscale.app/Contents/MacOS/Tailscale up

# Disconnect macos-main from the tailnet
macos-main-tailscale-down:
    /Applications/Tailscale.app/Contents/MacOS/Tailscale down
