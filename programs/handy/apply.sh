# shellcheck shell=bash disable=SC2154 # nix_settings is set by Nix
# `handy-apply-settings <settings_store.json>`: sets the Nix-owned keys of
# Handy's settings store and leaves every other key (API keys, microphone,
# onboarding) as found. Handy rewrites the whole file on every save, so it is
# Keyed, never Owned.

store=$1

mkdir -p "$(dirname "$store")"
[ -f "$store" ] || echo '{}' >"$store"
tmp=$(mktemp "$store.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq --slurpfile nix "$nix_settings" '.settings = (.settings // {}) * $nix[0]' \
  "$store" >"$tmp"
mv "$tmp" "$store"
