#!/usr/bin/env bash
set -euo pipefail
host=$1

case "$host" in
  "" | *[!a-z0-9-]*)
    echo "ERROR: invalid host name '$host' (expected [a-z0-9-])" >&2
    exit 1
    ;;
  *) ;;
esac
file="secrets/hosts/$host.yaml"
key_file=/var/lib/sops-age/keys.txt

sudo -v
if ! sudo -n test -f "$key_file"; then
  echo "ERROR: no age key at $key_file - restore it with: just darwin-install-age-key" >&2
  exit 1
fi
export SOPS_AGE_KEY_CMD="sudo -n cat $key_file"

# macOS has no mkpasswd and its libc cannot do yescrypt at all, so a Mac
# cannot hash a NixOS password without help. Use whatever is on PATH (the
# nixos-install shell ships it) and otherwise a flake.lock-pinned copy, the
# same way the `typos` recipe pins its tool. nixpkgs#mkpasswd, not
# nixpkgs#whois: the darwin build of whois carries no mkpasswd binary.
if command -v mkpasswd >/dev/null 2>&1; then
  mkpasswd_cmd=(mkpasswd)
else
  mkpasswd_cmd=(nix shell --inputs-from . nixpkgs#mkpasswd -c mkpasswd)
fi

# Read it twice ourselves: mkpasswd does not confirm, and a typo here locks
# you out of the host with no way to tell until you try to log in.
read -rsp "New password for $host: " pw
echo
read -rsp "Repeat: " pw2
echo
[ -n "$pw" ] || {
  echo "ERROR: empty password." >&2
  exit 1
}
[ "$pw" = "$pw2" ] || {
  echo "ERROR: passwords do not match." >&2
  exit 1
}

hash=$(printf '%s\n' "$pw" | "${mkpasswd_cmd[@]}" -m yescrypt -s)
unset pw pw2

mkdir -p secrets/hosts
if [ ! -f "$file" ]; then
  # sops cannot create an empty document, so seed one and set into it.
  # That keeps the hash on a single code path whether the file is new or
  # already holds other secrets, which `sops set` leaves untouched.
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  printf '{}\n' | sops -e --input-type json --output-type yaml \
    --filename-override "$file" /dev/stdin >"$tmp"
  mv "$tmp" "$file"
  echo "Created $file"
fi

# sops wants the value as JSON, and --value-stdin keeps it out of argv.
# mkpasswd emits one line of printable ASCII, so escaping " and \ covers it.
# shellcheck disable=SC2312 # sed over a variable does not fail
printf '"%s"' "$(printf '%s' "$hash" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" |
  sops set --value-stdin "$file" '["password-hash"]'

echo "Wrote password-hash to $file"
echo "Rebuild $host from this commit or later, or it will not take the new password."
