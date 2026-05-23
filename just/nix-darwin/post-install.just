# ─── Nix Darwin — Post-Install ───────────────────────────────────────────────
# Day-to-day commands for managing a macOS nix-darwin configuration.

# Rebuild and switch the system to the latest flake configuration.
darwin-rebuild host:
    sudo darwin-rebuild switch --flake .#{{host}}

# Dry-run: check the config compiles without applying it.
darwin-build host:
    darwin-rebuild build --flake .#{{host}}

# Roll back to the previous system generation.
darwin-rollback:
    sudo darwin-rebuild rollback

# List all system generations.
darwin-generations:
    sudo darwin-rebuild --list-generations

# Restore an existing age private key from BitWarden into the macOS SOPS default location.
# Paste the full keys.txt content in the terminal, then press Ctrl+D.
darwin-restore-age-key:
    mkdir -p "$HOME/Library/Application Support/sops/age"
    chmod 700 "$HOME/Library/Application Support/sops/age"
    echo ""
    echo "Paste the full keys.txt content from BitWarden, then press Ctrl+D:"
    echo ""
    tee "$HOME/Library/Application Support/sops/age/keys.txt" > /dev/null
    chmod 600 "$HOME/Library/Application Support/sops/age/keys.txt"
    grep -q "AGE-SECRET-KEY" "$HOME/Library/Application Support/sops/age/keys.txt" \
        || { echo "ERROR: no AGE-SECRET-KEY line found — check what you pasted"; exit 1; }
    echo ""
    echo "Age key restored. Public key:"
    age-keygen -y "$HOME/Library/Application Support/sops/age/keys.txt"
