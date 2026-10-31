#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "${BASH_SOURCE[0]%/*}/ssh-common.sh"
HOST=$(hostname -s)
# shellcheck disable=SC2311 # as it was inline: only the status of the last eval counts
EMAIL=$(ssh_email)
require_email "$EMAIL" "$HOST"
KEY="$HOME/.ssh/id_ed25519_sk"

require_fido_pin "this YubiKey" "The PIN is what protects the key if the token is stolen."

mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [ -f "$KEY" ]; then
  echo "ERROR: $KEY already exists. Use 'just rotate-ssh-key' to replace it." >&2
  exit 1
fi

echo "Generating resident ed25519-sk credential for host '$HOST'."
echo "You will be prompted for the FIDO2 PIN once, then asked to TAP the key."
generate_resident_key "$HOST" "$EMAIL" "$KEY" "$EMAIL"

# Decommission the old passphrase key (non-destructive: back it up, unload it).
OLD="$HOME/.ssh/id_ed25519"
BACKUP=""
if [ -f "$OLD" ]; then
  BACKUP="$HOME/.ssh/backups/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$BACKUP" && chmod 700 "$HOME/.ssh/backups" "$BACKUP"
  mv "$OLD" "$OLD.pub" "$BACKUP/" 2>/dev/null || true
  # shellcheck disable=SC2312 # uname does not fail
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
