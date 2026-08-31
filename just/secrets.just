# ─── Secrets ─────────────────────────────────────────────────────────────────

# The age private key is root-only by design (see docs/SOPS.md): sops-nix
# decrypts as root during activation, so nothing needs a user-readable copy.
# The sops CLI runs as your user, so it is fed the key over stdout from a
# privileged command instead - the key never lands in a file you own.
age_key_file := "/var/lib/sops-age/keys.txt"

# Prime the sudo timestamp and fail early if the age key is missing.
[private]
require-age-key:
    sudo -v
    sudo -n test -f {{ age_key_file }} \
        || { echo "ERROR: no age key at {{ age_key_file }} - restore it with: just darwin-install-age-key" >&2; exit 1; }

# Hash a new root password with yescrypt and open secrets/secrets.yaml to save it.
new-root-password:
    @echo "Enter the new root password (input hidden):"
    @echo ""
    hash=$(mkpasswd -m yescrypt)
    clear
    echo "Hashed password (copy this into secrets/secrets.yaml):"
    echo ""
    echo "$hash"
    echo ""
    read -rp "Press Enter to open secrets/secrets.yaml in your editor: "
    just edit-secrets

# Open secrets/secrets.yaml for editing.
edit-secrets: require-age-key
    SOPS_AGE_KEY_CMD='sudo -n cat {{ age_key_file }}' sops secrets/secrets.yaml
