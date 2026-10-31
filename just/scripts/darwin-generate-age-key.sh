#!/usr/bin/env bash
set -euo pipefail
key_file=/var/lib/sops-age/keys.txt
key_dir=$(dirname "$key_file")

if ! age_keygen=$(command -v age-keygen); then
  echo "ERROR: age-keygen not found on PATH - run inside 'nix develop .#darwin-install'" >&2
  exit 1
fi

sudo -v
if sudo -n test -e "$key_file"; then
  echo "ERROR: a key already exists at $key_file" >&2
  echo "Overwriting it would destroy access to every secret encrypted to it." >&2
  echo "To rotate deliberately, move the old key aside first:" >&2
  echo "  sudo mv $key_file $key_file.old" >&2
  exit 1
fi

sudo install -d -o root -g wheel -m 700 "$key_dir"
sudo "$age_keygen" -o "$key_file"
sudo chown root:wheel "$key_file"
sudo chmod 600 "$key_file"

# Verify rather than assume - this is the one file whose permissions matter.
dir_perms=$(sudo stat -f '%Sp %Su:%Sg' "$key_dir")
key_perms=$(sudo stat -f '%Sp %Su:%Sg' "$key_file")
if [ "$dir_perms" != "drwx------ root:wheel" ] || [ "$key_perms" != "-rw------- root:wheel" ]; then
  echo "ERROR: wrong permissions after generating:" >&2
  echo "  $key_dir: $dir_perms (want drwx------ root:wheel)" >&2
  echo "  $key_file: $key_perms (want -rw------- root:wheel)" >&2
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  SAVE THE KEY BELOW TO BITWARDEN - THIS IS THE ONLY COPY     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
sudo cat "$key_file"
echo ""
read -rp "Press Enter once you have saved the key to Bitwarden: "
clear

echo "Permissions verified:"
echo "  $key_dir  $dir_perms"
echo "  $key_file  $key_perms"
echo ""
echo "Public key (add this to .sops.yaml):"
sudo grep 'public key' "$key_file"
echo ""
echo "Next: add it to .sops.yaml, then run 'sops updatekeys' on every file"
echo "under secrets/ to authorise it, and commit .sops.yaml and secrets/."
