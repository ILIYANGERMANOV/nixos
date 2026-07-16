# ─── SSH / YubiKey ───────────────────────────────────────────────────────────
# This host's SSH key is a FIDO2 resident credential living INSIDE a YubiKey
# (ed25519-sk). It is used for both GitHub auth and git commit signing.
# The private key never touches disk; every op needs a physical tap.
# Full procedures: docs/SSH.md

# Look up this host's git email from either a darwin or nixos configuration.
_ssh_email := "HOST=$(hostname -s); nix eval --raw \".#darwinConfigurations.$HOST.config.myConfig.user.email\" 2>/dev/null || nix eval --raw \".#nixosConfigurations.$HOST.config.myConfig.user.email\""

# Preflight: show YubiKey model, firmware, and FIDO2 PIN status.
yubikey-check:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "── Device ──────────────────────────────────────────"
    ykman info
    echo ""
    echo "── FIDO2 ───────────────────────────────────────────"
    ykman fido info
    echo ""
    echo "ed25519-sk resident keys require firmware >= 5.2.3 and a FIDO2 PIN."
    echo "If no PIN is set, run: just yubikey-set-pin"

# Set (or change) the YubiKey's FIDO2 PIN. Store it in Bitwarden.
yubikey-set-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Set a FIDO2 PIN (4-63 chars). This PIN gates enrollment and key extraction"
    echo "(ssh-keygen -K). 8 wrong tries permanently wipe the FIDO2 applet."
    echo "STORE IT IN BITWARDEN before continuing."
    echo ""
    ykman fido access change-pin

# Test that you still remember the FIDO2 PIN (verifies without changing it).
yubikey-verify-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! ykman fido info 2>/dev/null | grep -qiE 'PIN:.*attempt'; then
      echo "ERROR: no FIDO2 PIN set on this YubiKey. Run 'just yubikey-set-pin' first." >&2
      exit 1
    fi
    echo "Enter your FIDO2 PIN to confirm you still know it."
    echo "A correct PIN resets the retry counter; wrong tries count toward the 8-strike wipe."
    echo ""
    ykman fido access verify-pin
    echo ""
    echo "✓ PIN verified — you still know it, and the retry counter is reset to full."

# Enroll the PRIMARY YubiKey for this host (generate the resident credential + stub).
setup-yubikey-ssh:
    #!/usr/bin/env bash
    set -euo pipefail
    HOST=$(hostname -s)
    EMAIL=$({{ _ssh_email }})
    if [ -z "$EMAIL" ]; then
      echo "ERROR: could not resolve this host's git email from the flake config." >&2
      echo "Check that '$HOST' is a valid darwin/nixos configuration." >&2
      exit 1
    fi
    KEY="$HOME/.ssh/id_ed25519_sk"

    if ! ykman fido info 2>/dev/null | grep -qiE 'PIN:.*attempt'; then
      echo "ERROR: no FIDO2 PIN set on this YubiKey. Run 'just yubikey-set-pin' first." >&2
      echo "The PIN is what protects the key if the token is stolen." >&2
      exit 1
    fi

    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    if [ -f "$KEY" ]; then
      echo "ERROR: $KEY already exists. Use 'just rotate-ssh-key' to replace it." >&2
      exit 1
    fi

    echo "Generating resident ed25519-sk credential for host '$HOST'."
    echo "You will be prompted for the FIDO2 PIN once, then asked to TAP the key."
    ssh-keygen -t ed25519-sk -O resident -O application=ssh:$HOST \
      -O user="$EMAIL" -f "$KEY" -N "" -C "$EMAIL"
    chmod 600 "$KEY"
    chmod 644 "$KEY.pub"

    # Decommission the old passphrase key (non-destructive: back it up, unload it).
    OLD="$HOME/.ssh/id_ed25519"
    BACKUP=""
    if [ -f "$OLD" ]; then
      BACKUP="$HOME/.ssh/backups/$(date +%Y%m%d_%H%M%S)"
      mkdir -p "$BACKUP" && chmod 700 "$HOME/.ssh/backups" "$BACKUP"
      mv "$OLD" "$OLD.pub" "$BACKUP/" 2>/dev/null || true
      if [ "$(uname)" = "Darwin" ]; then
        ssh-add --apple-use-keychain -d "$BACKUP/id_ed25519" 2>/dev/null || true
      else
        ssh-add -d "$BACKUP/id_ed25519" 2>/dev/null || true
      fi
      echo "Old key backed up to $BACKUP and unloaded from the agent."
    fi

    echo ""
    echo "=========================================================================="
    echo "Add this PRIMARY public key to GitHub TWICE at https://github.com/settings/ssh/new"
    echo "  1) Key type: Authentication Key   2) Key type: Signing Key"
    echo "--------------------------------------------------------------------------"
    cat "$KEY.pub"
    echo "=========================================================================="
    echo "Next:"
    echo "  * Enroll the BACKUP YubiKey:  just enroll-backup-yubikey"
    echo "  * Verify:  ssh -T git@github.com   (expect a tap)"
    echo "  * Then delete the OLD key's two GitHub entries at https://github.com/settings/keys"
    if [ -n "$BACKUP" ]; then
      echo "  * Once verified, wipe the old key backup:  rm -rf \"$BACKUP\""
    fi

# Enroll the BACKUP YubiKey for this host (plug in the SECOND key first).
enroll-backup-yubikey:
    #!/usr/bin/env bash
    set -euo pipefail
    HOST=$(hostname -s)
    EMAIL=$({{ _ssh_email }})
    if [ -z "$EMAIL" ]; then
      echo "ERROR: could not resolve this host's git email from the flake config." >&2
      echo "Check that '$HOST' is a valid darwin/nixos configuration." >&2
      exit 1
    fi
    KEY="$HOME/.ssh/id_ed25519_sk_backup"

    if ! ykman fido info 2>/dev/null | grep -qiE 'PIN:.*attempt'; then
      echo "ERROR: no FIDO2 PIN set on the plugged-in YubiKey. Run 'just yubikey-set-pin' first." >&2
      exit 1
    fi
    if [ -f "$KEY" ]; then
      echo "ERROR: $KEY already exists. Use 'just rotate-ssh-key backup' to replace it." >&2
      exit 1
    fi

    echo "Make sure your BACKUP YubiKey is the one plugged in."
    echo "Generating resident ed25519-sk credential for host '$HOST' on the backup key."
    ssh-keygen -t ed25519-sk -O resident -O application=ssh:$HOST \
      -O user="$EMAIL" -f "$KEY" -N "" -C "$EMAIL (backup)"
    chmod 600 "$KEY"
    chmod 644 "$KEY.pub"

    echo ""
    echo "=========================================================================="
    echo "Add this BACKUP public key to GitHub TWICE at https://github.com/settings/ssh/new"
    echo "  1) Key type: Authentication Key   2) Key type: Signing Key"
    echo "--------------------------------------------------------------------------"
    cat "$KEY.pub"
    echo "=========================================================================="
    echo "Store the backup YubiKey somewhere safe (drawer/safe)."

# Restore the local stub file on a fresh/rebuilt machine from the plugged-in YubiKey.
# Prompts for the FIDO2 PIN — this is why a stolen token alone is useless.
restore-ssh-stubs which="primary":
    #!/usr/bin/env bash
    set -euo pipefail
    HOST=$(hostname -s)
    case "{{ which }}" in
      primary) DEST="$HOME/.ssh/id_ed25519_sk" ;;
      backup)  DEST="$HOME/.ssh/id_ed25519_sk_backup" ;;
      *) echo "Usage: just restore-ssh-stubs [primary|backup]" >&2; exit 1 ;;
    esac

    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    echo "Downloading resident credentials from the plugged-in YubiKey (PIN + tap)."
    ( cd "$TMP" && ssh-keygen -K )

    # ssh-keygen -K writes id_ed25519_sk_rk_<application>[.pub]; the application
    # suffix encoding varies, so match on the host substring defensively.
    MATCH=$(find "$TMP" -maxdepth 1 -name "id_ed25519_sk_rk*" ! -name "*.pub" \
      | grep -i "$HOST" | head -n1 || true)
    if [ -z "$MATCH" ]; then
      echo "Could not find a credential for host '$HOST'. Files downloaded:" >&2
      find "$TMP" -maxdepth 1 -name "id_ed25519_sk_rk*" >&2
      exit 1
    fi
    install -m 600 "$MATCH" "$DEST"
    install -m 644 "$MATCH.pub" "$DEST.pub"
    echo "Restored {{ which }} stub to $DEST"
    echo "Verify: ssh -T git@github.com"

# Rotate this host's credential on the plugged-in YubiKey (delete + regenerate).
# which: primary | backup (required) — selects the local stub file to replace.
rotate-ssh-key which:
    #!/usr/bin/env bash
    set -euo pipefail
    HOST=$(hostname -s)
    EMAIL=$({{ _ssh_email }})
    if [ -z "$EMAIL" ]; then
      echo "ERROR: could not resolve this host's git email from the flake config." >&2
      echo "Check that '$HOST' is a valid darwin/nixos configuration." >&2
      exit 1
    fi
    case "{{ which }}" in
      primary) KEY="$HOME/.ssh/id_ed25519_sk"; COMMENT="$EMAIL" ;;
      backup)  KEY="$HOME/.ssh/id_ed25519_sk_backup"; COMMENT="$EMAIL (backup)" ;;
      *) echo "Usage: just rotate-ssh-key [primary|backup]" >&2; exit 1 ;;
    esac

    echo "Existing resident credentials on the plugged-in YubiKey:"
    ykman fido credentials list || true
    echo ""
    echo "Deleting the old 'ssh:$HOST' credential (PIN required)..."
    ykman fido credentials delete "ssh:$HOST" || \
      echo "(none matched 'ssh:$HOST' — continuing to regenerate)"

    if [ -f "$KEY" ]; then
      BACKUP="$HOME/.ssh/backups/$(date +%Y%m%d_%H%M%S)"
      mkdir -p "$BACKUP" && chmod 700 "$HOME/.ssh/backups" "$BACKUP"
      mv "$KEY" "$KEY.pub" "$BACKUP/" 2>/dev/null || true
    fi

    ssh-keygen -t ed25519-sk -O resident -O application=ssh:$HOST \
      -O user="$EMAIL" -f "$KEY" -N "" -C "$COMMENT"
    chmod 600 "$KEY"
    chmod 644 "$KEY.pub"

    echo ""
    echo "=========================================================================="
    echo "Add the NEW public key to GitHub (Authentication + Signing) BEFORE deleting the old:"
    echo "--------------------------------------------------------------------------"
    cat "$KEY.pub"
    echo "=========================================================================="
    echo "Then delete the old entries at https://github.com/settings/keys"
    echo "Note: deleting a Signing key flips its past commits to Unverified (recomputed live)."
