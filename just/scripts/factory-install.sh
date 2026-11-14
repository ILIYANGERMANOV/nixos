#!/usr/bin/env bash
# Installs factory $1 on the machine at IPv4 $2 with nixos-anywhere over root
# SSH, wiping its disk. The age key is pasted from Bitwarden into a private temp
# directory that nixos-anywhere copies to the new root, and the directory is
# removed on exit. The system is built on the target: a Mac cannot build
# x86_64-linux.
#
# Root SSH differs by platform:
#   hetzner        - the key Hetzner put on the fresh server (YubiKey, or the
#                    throwaway one from factory-install-key). Whatever runs
#                    there is replaced by a NixOS installer (kexec).
#   thinkpad-t15p  - the NixOS minimal ISO booted on the laptop, after
#                    `passwd` there. The password reaches nixos-anywhere in
#                    SSHPASS, never argv; it copies a key of its own over with
#                    it. The ISO is an installer already, so there is no kexec.
set -euo pipefail
host=$1
ip=$2
platform=$(bash "$(dirname "$0")/factory-host.sh" "$host")
case "$ip" in
  *[!0-9.]* | "")
    echo "ERROR: expected an IPv4 address, got '$ip'" >&2
    exit 1
    ;;
  *) ;;
esac

# Empty for Hetzner. Expanded with ${login[@]+...}: macOS's bash 3.2 calls an
# empty array unbound under set -u.
login=()
case "$platform" in
  hetzner) ;;
  thinkpad-t15p)
    read -rsp "The root password you set with passwd on the laptop: " SSHPASS
    echo
    [ -n "$SSHPASS" ] || {
      echo "ERROR: empty password." >&2
      exit 1
    }
    export SSHPASS
    login=(--env-password)
    ;;
  *)
    echo "ERROR: unknown platform '$platform'." >&2
    exit 1
    ;;
esac

extra=$(mktemp -d)
trap 'rm -rf "$extra"' EXIT
install -d -m 700 "$extra/var/lib/sops-age"

echo "Paste '$host-age-key' from Bitwarden, then press Ctrl-D on a new line:"
(
  umask 077
  cat >"$extra/var/lib/sops-age/keys.txt"
)
grep -q '^AGE-SECRET-KEY-1' "$extra/var/lib/sops-age/keys.txt" || {
  echo "ERROR: does not look like an age private key." >&2
  exit 1
}

nix run --inputs-from . nixpkgs#nixos-anywhere -- \
  --flake ".#$host" \
  --build-on remote \
  ${login[@]+"${login[@]}"} \
  --extra-files "$extra" \
  --target-host "root@$ip"

case "$platform" in
  hetzner) echo "Installed. Remove the temporary inbound SSH rule from the Hetzner firewall now." ;;
  thinkpad-t15p) echo "Installed. Pull the USB stick out; the laptop boots NixOS and joins the tailnet." ;;
  *) ;;
esac
