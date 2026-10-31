# shellcheck shell=bash
# What the YubiKey SSH recipes share: this host's git email, the FIDO2 PIN gate
# and enrolling the resident credential. Sourced from the repository root.

# Prints this host's git email from either a darwin or nixos configuration. Call
# it as `EMAIL=$(ssh_email)`, so that an eval failing stops the caller there.
ssh_email() {
  HOST=$(hostname -s)
  nix eval --raw ".#darwinConfigurations.$HOST.config.myConfig.user.email" 2>/dev/null || nix eval --raw ".#nixosConfigurations.$HOST.config.myConfig.user.email"
}

# require_email <email> <host>
require_email() {
  if [ -z "$1" ]; then
    echo "ERROR: could not resolve this host's git email from the flake config." >&2
    echo "Check that '$2' is a valid darwin/nixos configuration." >&2
    exit 1
  fi
}

# require_fido_pin <device words> [extra error lines...]
require_fido_pin() {
  local device=$1 line
  shift
  if ! ykman fido info 2>/dev/null | grep -qiE 'PIN:.*attempt'; then
    echo "ERROR: no FIDO2 PIN set on $device. Run 'just yubikey-set-pin' first." >&2
    for line in "$@"; do
      echo "$line" >&2
    done
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
