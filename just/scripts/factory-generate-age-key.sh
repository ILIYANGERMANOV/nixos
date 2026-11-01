#!/usr/bin/env bash
set -euo pipefail
marker='# software-factory-age-key: not generated yet'
grep -qF "$marker" .sops.yaml || {
  echo "ERROR: .sops.yaml already lists a software-factory key." >&2
  echo "A new key cannot decrypt secrets/hosts/software-factory.yaml; to rotate," >&2
  echo "put the marker line back by hand and re-encrypt with 'sops updatekeys'." >&2
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
echo "'software-factory-age-key' (the whole text, both lines)."
read -rsp "Press Enter once saved - the clipboard is cleared in 120s either way. " -t 120 || true
echo
pbcopy </dev/null
echo "Clipboard cleared."

sed -i '' "s|$marker|- $public # software-factory|" .sops.yaml
echo "Added $public to .sops.yaml."
echo "Next: just factory-secrets"
