# ─── Secrets ─────────────────────────────────────────────────────────────────

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
    sops secrets/secrets.yaml

# Open secrets/secrets.yaml for editing.
edit-secrets:
    sops secrets/secrets.yaml
