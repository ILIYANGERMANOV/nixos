# ─── Nix Darwin — Install ────────────────────────────────────────────────────
# One-time setup commands for bootstrapping nix-darwin on a new macOS machine.

# Set all three macOS hostname values (required before first bootstrap).
darwin-set-hostname host:
    sudo scutil --set LocalHostName {{host}}
    sudo scutil --set ComputerName {{host}}
    sudo scutil --set HostName {{host}}

# Back up /etc shell files that nix-darwin will replace (required before first bootstrap).
darwin-backup-etc:
    sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
    sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
    sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin

# Bootstrap nix-darwin for the first time on a machine (run after darwin-set-hostname and darwin-backup-etc).
darwin-bootstrap host:
    sudo nix run --extra-experimental-features 'nix-command flakes' \
      'github:nix-darwin/nix-darwin/nix-darwin-25.11#darwin-rebuild' \
      -- switch --flake .#{{host}}

# Install the SOPS age private key (paste from Bitwarden, then press Ctrl-D on a new line).
# Must run before darwin-bootstrap so sops-nix can decrypt secrets during activation.
darwin-install-age-key:
    @echo "Open Bitwarden, copy your age private key, paste it below, then press Ctrl-D on a new line:"
    @echo ""
    key=$(cat); \
    if ! printf '%s\n' "$key" | grep -q 'AGE-SECRET-KEY-1'; then \
      echo "Error: does not look like an age private key (missing AGE-SECRET-KEY-1 line)." >&2; \
      exit 1; \
    fi; \
    sudo mkdir -p /var/lib/sops-age; \
    printf '%s\n' "$key" | sudo tee /var/lib/sops-age/keys.txt > /dev/null; \
    sudo chown root:wheel /var/lib/sops-age; \
    sudo chmod 700 /var/lib/sops-age; \
    sudo chown root:wheel /var/lib/sops-age/keys.txt; \
    sudo chmod 600 /var/lib/sops-age/keys.txt; \
    echo ""; \
    echo "Age key installed. Public key:"; \
    sudo grep 'public key' /var/lib/sops-age/keys.txt
