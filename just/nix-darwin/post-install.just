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
