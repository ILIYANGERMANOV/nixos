# shellcheck shell=bash
# What the YubiKey SSH recipes share: this host's git email, the FIDO2 PIN gate
# and enrolling the resident credential.

# Sets HOST to this machine's short name and EMAIL to its git email, from either
# a darwin or nixos configuration. Exits when neither resolves one.
ssh_identity() {
  HOST=$(hostname -s)
  EMAIL=$(nix eval --raw ".#darwinConfigurations.$HOST.config.myConfig.user.email" 2>/dev/null || nix eval --raw ".#nixosConfigurations.$HOST.config.myConfig.user.email")
  if [ -z "$EMAIL" ]; then
    echo "ERROR: could not resolve this host's git email from the flake config." >&2
    echo "Check that '$HOST' is a valid darwin/nixos configuration." >&2
    exit 1
  fi
}

# require_fido_pin <device words> [hint line]
require_fido_pin() {
  # shellcheck disable=SC2312 # the sourcing script sets pipefail
  if ! ykman fido info 2>/dev/null | grep -qiE 'PIN:.*attempt'; then
    echo "ERROR: no FIDO2 PIN set on $1. Run 'just yubikey-set-pin' first." >&2
    [ -z "${2:-}" ] || echo "$2" >&2
    exit 1
  fi
}

# generate_resident_key <host> <email> <key> <comment>
# The caller's terminal stays ssh-keygen's: never call this inside a `$(...)`.
generate_resident_key() {
  local host=$1 email=$2 key=$3 comment=$4
  ssh-keygen -t ed25519-sk -O resident -O application=ssh:"$host" \
    -O user="$email" -f "$key" -N "" -C "$comment"
  chmod 600 "$key"
  chmod 644 "$key.pub"
}
