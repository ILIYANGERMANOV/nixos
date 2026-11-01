#!/usr/bin/env bash
set -euo pipefail
which=$1
# shellcheck source=/dev/null
source "${BASH_SOURCE[0]%/*}/ssh-common.sh"
ssh_identity
case "$which" in
  primary)
    KEY="$HOME/.ssh/id_ed25519_sk"
    COMMENT="$EMAIL"
    ;;
  backup)
    KEY="$HOME/.ssh/id_ed25519_sk_backup"
    COMMENT="$EMAIL (backup)"
    ;;
  *)
    echo "Usage: just rotate-ssh-key [primary|backup]" >&2
    exit 1
    ;;
esac

echo "Existing resident credentials on the plugged-in YubiKey:"
ykman fido credentials list || true
echo ""
echo "Deleting the old 'ssh:$HOST' credential (PIN required)..."
ykman fido credentials delete "ssh:$HOST" ||
  echo "(none matched 'ssh:$HOST' — continuing to regenerate)"

if [ -f "$KEY" ]; then
  BACKUP="$HOME/.ssh/backups/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$BACKUP" && chmod 700 "$HOME/.ssh/backups" "$BACKUP"
  mv "$KEY" "$KEY.pub" "$BACKUP/" 2>/dev/null || true
fi

generate_resident_key "$HOST" "$EMAIL" "$KEY" "$COMMENT"

echo ""
echo "=========================================================================="
echo "Add the NEW public key to GitHub (Authentication + Signing) BEFORE deleting the old:"
echo "--------------------------------------------------------------------------"
cat "$KEY.pub"
echo "=========================================================================="
echo "Then delete the old entries at https://github.com/settings/keys"
echo "Note: deleting a Signing key flips its past commits to Unverified (recomputed live)."
