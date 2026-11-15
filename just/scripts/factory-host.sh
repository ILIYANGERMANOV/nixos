#!/usr/bin/env bash
# Prints the platform of the factory named $1, from `factories` in flake.nix
# (the flake's lib.factories), or fails naming the factories there are. Every
# factory recipe passes its host through here before using it, so a host is one
# of a fixed set of [a-z0-9-] names by the time it reaches a path or ssh.
set -euo pipefail
host=$1

# shellcheck disable=SC2016 # ${n} is Nix interpolation, not the shell's
factories=$(nix eval --raw .#lib.factories --apply \
  'f: builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (n: p: "${n} ${p}") f))')
platform=$(awk -v host="$host" '$1 == host { print $2 }' <<<"$factories")
[ -n "$platform" ] || {
  names=$(awk '{ print $1 }' <<<"$factories" | paste -sd ' ' -)
  echo "ERROR: '$host' is not a software factory. Factories (flake.nix): $names" >&2
  exit 1
}
echo "$platform"
