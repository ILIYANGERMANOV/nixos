# ─── Secrets ─────────────────────────────────────────────────────────────────

# Secrets live in two files, matching the two scopes of `myConfig.secrets`:
#
#   secrets/common.yaml            global — every host decrypts it
#   secrets/hosts/<hostname>.yaml  host   — only hosts that declare the secret
#
# The age private key is root-only by design (see docs/SOPS.md): sops-nix
# decrypts as root during activation, so nothing needs a user-readable copy.
# The sops CLI runs as your user, so it is fed the key over stdout from a
# privileged command instead - the key never lands in a file you own.
#
# The key path is a shell variable inside each recipe, not a just variable: just
# interpolates `{{ ... }}` textually before bash parses the line, so an
# overridable variable would let `just age_key_file=... edit-secrets` inject
# arbitrary commands into SOPS_AGE_KEY_CMD.
#
# For the same reason the host parameter is declared as `$host`, not `host`:
# the `$` makes just pass it as an ENVIRONMENT VARIABLE rather than splicing it
# into the recipe text, so `just edit-secrets '; rm -rf /'` is inert. The
# character-class check below is defence in depth on top of that.

# Nothing to copy-paste: the hash goes straight into the encrypted file and
# never reaches the screen, the clipboard or a plaintext file. The password
# reaches mkpasswd down a pipe and the hash reaches sops on stdin, so neither
# ever appears in a process listing.
#
# This is the LOGIN user's password, not root's - `users.mutableUsers` is false
# and root has no password at all; you reach it through sudo.

# Hash a password with yescrypt into <host>'s secrets file as `password-hash`
set-password-hash $host:
    #!/usr/bin/env bash
    set -euo pipefail

    case "$host" in
        ""|*[!a-z0-9-]*)
            echo "ERROR: invalid host name '$host' (expected [a-z0-9-])" >&2
            exit 1
            ;;
    esac
    file="secrets/hosts/$host.yaml"
    key_file=/var/lib/sops-age/keys.txt

    sudo -v
    if ! sudo -n test -f "$key_file"; then
        echo "ERROR: no age key at $key_file - restore it with: just darwin-install-age-key" >&2
        exit 1
    fi
    export SOPS_AGE_KEY_CMD="sudo -n cat $key_file"

    # macOS has no mkpasswd and its libc cannot do yescrypt at all, so a Mac
    # cannot hash a NixOS password without help. Use whatever is on PATH (the
    # nixos-install shell ships it) and otherwise a flake.lock-pinned copy, the
    # same way the `typos` recipe pins its tool. nixpkgs#mkpasswd, not
    # nixpkgs#whois: the darwin build of whois carries no mkpasswd binary.
    if command -v mkpasswd >/dev/null 2>&1; then
        mkpasswd_cmd=(mkpasswd)
    else
        mkpasswd_cmd=(nix shell --inputs-from . nixpkgs#mkpasswd -c mkpasswd)
    fi

    # Read it twice ourselves: mkpasswd does not confirm, and a typo here locks
    # you out of the host with no way to tell until you try to log in.
    read -rsp "New password for $host: " pw; echo
    read -rsp "Repeat: " pw2; echo
    [ -n "$pw" ] || { echo "ERROR: empty password." >&2; exit 1; }
    [ "$pw" = "$pw2" ] || { echo "ERROR: passwords do not match." >&2; exit 1; }

    hash=$(printf '%s\n' "$pw" | "${mkpasswd_cmd[@]}" -m yescrypt -s)
    unset pw pw2

    mkdir -p secrets/hosts
    if [ ! -f "$file" ]; then
        # sops cannot create an empty document, so seed one and set into it.
        # That keeps the hash on a single code path whether the file is new or
        # already holds other secrets, which `sops set` leaves untouched.
        tmp=$(mktemp)
        trap 'rm -f "$tmp"' EXIT
        printf '{}\n' | sops -e --input-type json --output-type yaml \
            --filename-override "$file" /dev/stdin > "$tmp"
        mv "$tmp" "$file"
        echo "Created $file"
    fi

    # sops wants the value as JSON, and --value-stdin keeps it out of argv.
    # mkpasswd emits one line of printable ASCII, so escaping " and \ covers it.
    printf '"%s"' "$(printf '%s' "$hash" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
        | sops set --value-stdin "$file" '["password-hash"]'

    echo "Wrote password-hash to $file"
    echo "Rebuild $host from this commit or later, or it will not take the new password."

# Open a secrets file: no argument for the global one, a hostname for that host's.
edit-secrets $host="":
    #!/usr/bin/env bash
    set -euo pipefail
    key_file=/var/lib/sops-age/keys.txt

    if [ -z "$host" ]; then
        file=secrets/common.yaml
    else
        case "$host" in
            *[!a-z0-9-]*)
                echo "ERROR: invalid host name '$host' (expected [a-z0-9-])" >&2
                exit 1
                ;;
        esac
        mkdir -p secrets/hosts
        file="secrets/hosts/$host.yaml"
    fi

    sudo -v
    if ! sudo -n test -f "$key_file"; then
        echo "ERROR: no age key at $key_file - restore it with: just darwin-install-age-key" >&2
        exit 1
    fi

    # sops creates the file from .sops.yaml's creation_rules when it is absent,
    # so this is also how a new host's secrets file comes into existence.
    if [ ! -f "$file" ]; then
        echo "Creating $file (it does not exist yet)."
    fi
    SOPS_AGE_KEY_CMD="sudo -n cat $key_file" sops "$file"
