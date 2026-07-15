# ─── SSH ─────────────────────────────────────────────────────────────────────
# Manage this machine's SSH key (used for both GitHub auth and commit signing).

# Rotate this machine's SSH key: back up the old one, generate a new passphrase-protected key.
rotate-ssh-key:
    #!/usr/bin/env bash
    set -euo pipefail
    KEY="$HOME/.ssh/id_ed25519"
    EMAIL=$(nix eval --raw ".#darwinConfigurations.$(hostname -s).config.myConfig.user.email")
    if [ -f "$KEY" ]; then
      BACKUP="$HOME/.ssh/backups/$(date +%Y%m%d_%H%M%S)"
      mkdir -p "$BACKUP" && chmod 700 "$HOME/.ssh/backups" "$BACKUP"
      mv "$KEY" "$KEY.pub" "$BACKUP/" 2>/dev/null || true
      echo "Old key backed up to $BACKUP"
    fi
    # -a 100: 100 KDF rounds, hardening the on-disk (encrypted) key against brute force.
    # ssh-keygen prompts for the passphrase interactively — type one you'll remember.
    ssh-keygen -t ed25519 -a 100 -f "$KEY" -C "$EMAIL"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$KEY"
    chmod 644 "$KEY.pub"
    if [ "$(uname)" = "Darwin" ]; then
      ssh-add --apple-use-keychain "$KEY"
    fi
    echo ""
    echo "=========================================================================="
    echo "Add this public key to GitHub TWICE at https://github.com/settings/ssh/new"
    echo "  1) Key type: Authentication Key   2) Key type: Signing Key"
    echo "--------------------------------------------------------------------------"
    cat "$KEY.pub"
    echo "=========================================================================="
    echo "Then verify:  \`ssh -T git@github.com\`"
    echo "Then DELETE the old key (both entries) at https://github.com/settings/keys"
    if [ -n "${BACKUP:-}" ]; then
      echo "--------------------------------------------------------------------------"
      echo "Once verified, securely wipe the backed-up old key:"
      echo "  \`rm -rf \"$BACKUP\"\`"
    fi
