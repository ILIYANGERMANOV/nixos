# shellcheck shell=bash disable=SC2154 # nix_settings is set by Nix
# `handy-apply-settings <settings_store.json>`: sets the Nix-owned keys of
# Handy's settings store and leaves every other key (API keys, microphone,
# onboarding) as found. Handy rewrites the whole file on every save, so it is
# Keyed, never Owned.

# shellcheck disable=SC2016 # $nix is jq's variable, not the shell's
keyed-json-update "$1" '.settings = (.settings // {}) * $nix[0]' "$nix_settings"
