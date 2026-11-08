#!/usr/bin/env bash
# Generates factory $1's age key into the clipboard, for Bitwarden, and puts its
# public half in place of the host's marker line in .sops.yaml. An existing
# secrets file is re-encrypted to the new key. macOS only: pbcopy, sed -i ''.
set -euo pipefail
host=$1
bash "$(dirname "$0")/factory-host.sh" "$host" >/dev/null
file="secrets/hosts/$host.yaml"
marker="# $host-age-key: not generated yet"
grep -qF "$marker" .sops.yaml || {
  echo "ERROR: .sops.yaml has no line '$marker'." >&2
  echo "Either $host's key is listed already - a new key cannot decrypt $file;" >&2
  echo "to rotate, put the marker line back by hand - or $host has no rule there yet." >&2
  exit 1
}

if command -v age-keygen >/dev/null 2>&1; then
  age_keygen=(age-keygen)
else
  age_keygen=(nix shell --inputs-from . nixpkgs#age -c age-keygen)
fi

key=$("${age_keygen[@]}" 2>/dev/null)
public=$(printf '%s\n' "$key" | sed -n 's/^# public key: //p')
[ -n "$public" ] || {
  echo "ERROR: age-keygen produced no public key." >&2
  exit 1
}

printf '%s\n' "$key" | pbcopy
unset key
echo "The private key is on the clipboard. Save it in Bitwarden as"
echo "'$host-age-key' (the whole text, both lines)."
read -rsp "Press Enter once saved - the clipboard is cleared in 120s either way. " -t 120 || true
echo
pbcopy </dev/null
echo "Clipboard cleared."

sed -i '' "s|$marker|- $public # $host|" .sops.yaml
echo "Added $public to .sops.yaml."

# A file encrypted before the key existed (to macos-main alone) gets the new
# recipient; without one, factory-secrets creates it from the rule.
if [ -f "$file" ]; then
  sudo -v
  SOPS_AGE_KEY_CMD="sudo -n cat /var/lib/sops-age/keys.txt" sops updatekeys -y "$file"
  echo "Re-encrypted $file to $host's key."
fi
echo "Next: just factory-secrets $host"
