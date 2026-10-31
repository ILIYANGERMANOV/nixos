#!/usr/bin/env bash
set -euo pipefail
file=secrets/hosts/software-factory.yaml
key_file=/var/lib/sops-age/keys.txt

if grep -qF '# software-factory-age-key: not generated yet' .sops.yaml; then
  echo "ERROR: run 'just factory-generate-age-key' first, or the server" >&2
  echo "could not decrypt its own secrets." >&2
  exit 1
fi

just set-password-hash software-factory

sudo -v
export SOPS_AGE_KEY_CMD="sudo -n cat $key_file"

if command -v jq >/dev/null 2>&1; then
  jq_cmd=(jq)
else
  jq_cmd=(nix run --inputs-from . nixpkgs#jq --)
fi

# sops wants the value as JSON; jq -R quotes and escapes it.
set_secret() {
  local name="$1" prompt="$2" value
  read -rsp "$prompt: " value
  echo
  [ -n "$value" ] || {
    echo "ERROR: $name is empty." >&2
    exit 1
  }
  printf '%s' "$value" | "${jq_cmd[@]}" -R . | sops set --value-stdin "$file" "[\"$name\"]"
  echo "Wrote $name."
}

echo "Tailscale admin console > Settings > Keys: a one-off, pre-approved auth key"
echo "tagged tag:factory. Apply tailscale/policy.hujson first (just tailscale-apply)."
set_secret tailscale-authkey "Tailscale auth key"

echo "Bot account > Settings > Developer settings > Tokens (classic): scope 'repo' only."
set_secret gh-token "Bot GitHub token"

printf '"%s"' "unused" | sops set --value-stdin "$file" '["example-global"]'

just factory-deploy-token
echo "Done. Commit .sops.yaml and $file."
