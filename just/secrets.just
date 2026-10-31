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
[positional-arguments]
set-password-hash $host:
    @bash just/scripts/set-password-hash.sh "$@"

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
            *) ;;
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
