#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "${BASH_SOURCE[0]%/*}/ssh-common.sh"
HOST=$(hostname -s)
# shellcheck disable=SC2311 # as it was inline: only the status of the last eval counts
EMAIL=$(ssh_email)
require_email "$EMAIL" "$HOST"
KEY="$HOME/.ssh/id_ed25519_sk_backup"

require_fido_pin "the plugged-in YubiKey"
if [ -f "$KEY" ]; then
  echo "ERROR: $KEY already exists. Use 'just rotate-ssh-key backup' to replace it." >&2
  exit 1
fi

echo "Make sure your BACKUP YubiKey is the one plugged in."
echo "Generating resident ed25519-sk credential for host '$HOST' on the backup key."
generate_resident_key "$HOST" "$EMAIL" "$KEY" "$EMAIL (backup)"

echo ""
echo "=========================================================================="
echo "Add this BACKUP public key to GitHub TWICE at https://github.com/settings/ssh/new"
echo "  1) Key type: Authentication Key   2) Key type: Signing Key"
echo "--------------------------------------------------------------------------"
cat "$KEY.pub"
echo "=========================================================================="
echo "Store the backup YubiKey somewhere safe (drawer/safe)."
