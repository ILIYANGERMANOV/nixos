#!/usr/bin/env bash
# Writes every secret factory $1 declares into secrets/hosts/$1.yaml, creating
# the file when the host has none. A ThinkPad also needs the Wi-Fi network.
set -euo pipefail
host=$1
platform=$(bash "$(dirname "$0")/factory-host.sh" "$host")
file="secrets/hosts/$host.yaml"
key_file=/var/lib/sops-age/keys.txt

if grep -qF "# $host-age-key: not generated yet" .sops.yaml; then
  echo "ERROR: run 'just factory-generate-age-key $host' first, or the server" >&2
  echo "could not decrypt its own secrets." >&2
  exit 1
fi

# Creates the file from .sops.yaml's rule when it is missing.
just set-password-hash "$host"

sudo -v
export SOPS_AGE_KEY_CMD="sudo -n cat $key_file"

# sops wants the value as JSON.
set_secret() {
  local name="$1" prompt="$2" value
  read -rsp "$prompt: " value
  echo
  [ -n "$value" ] || {
    echo "ERROR: $name is empty." >&2
    exit 1
  }
  printf '%s' "$value" | just _json-string | sops set --value-stdin "$file" "[\"$name\"]"
  echo "Wrote $name."
}

echo "Tailscale admin console > Settings > Keys: a one-off, pre-approved auth key"
echo "tagged tag:factory. Apply tailscale/policy.hujson first (just tailscale-apply)."
set_secret tailscale-authkey "Tailscale auth key"

echo "Bot account > Settings > Developer settings > Tokens (classic): scope 'repo' only."
set_secret gh-token "Bot GitHub token"

printf '"%s"' "unused" | sops set --value-stdin "$file" '["example-global"]'

just factory-deploy-token "$host"

case "$platform" in
  hetzner) ;;
  thinkpad-t15p) just factory-wifi "$host" ;;
  *)
    echo "ERROR: unknown platform '$platform'." >&2
    exit 1
    ;;
esac
echo "Done. Next: just factory-secrets-commit $host"
