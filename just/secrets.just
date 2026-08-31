# ─── Secrets ─────────────────────────────────────────────────────────────────

# The age private key is root-only by design (see docs/SOPS.md): sops-nix
# decrypts as root during activation, so nothing needs a user-readable copy.
# The sops CLI runs as your user, so it is fed the key over stdout from a
# privileged command instead - the key never lands in a file you own.
#
# The path is a shell variable inside the recipe, not a just variable: just
# interpolates `{{ ... }}` textually before bash parses the line, so an
# overridable variable would let `just age_key_file=... edit-secrets` inject
# arbitrary commands into SOPS_AGE_KEY_CMD.

# Hash a new root password with yescrypt and open secrets/secrets.yaml to save it.
new-root-password:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Enter the new root password (input hidden):"
    echo ""
    hash=$(mkpasswd -m yescrypt)
    clear
    echo "Hashed password (copy this into secrets/secrets.yaml):"
    echo ""
    echo "$hash"
    echo ""
    read -rp "Press Enter to open secrets/secrets.yaml in your editor: "
    just edit-secrets

# Open secrets/secrets.yaml for editing.
edit-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    key_file=/var/lib/sops-age/keys.txt
    sudo -v
    if ! sudo -n test -f "$key_file"; then
        echo "ERROR: no age key at $key_file - restore it with: just darwin-install-age-key" >&2
        exit 1
    fi
    SOPS_AGE_KEY_CMD="sudo -n cat $key_file" sops secrets/secrets.yaml
