#!/usr/bin/env bats

load ../shell-check/test_helper

setup() {
  store="$BATS_TEST_TMPDIR/com.pais.handy/settings_store.json"
  export nix_settings="$BATS_TEST_TMPDIR/nix.json"
  echo '{"selected_model": "whisper-large-v3-turbo", "bindings": {"transcribe": {"current_binding": "option_right"}}}' >"$nix_settings"
}

apply() { bash -euo pipefail "$BATS_TEST_DIRNAME/apply.sh" "$store"; }

# Whether the jq filter $1 is true of the store.
holds() { jq -e "$1" "$store" >/dev/null; }

a_store_handy_wrote() {
  mkdir -p "$(dirname "$store")"
  echo '{"settings": {"selected_model": "small", "post_process_api_keys": {"openai": "sk-x"}, "bindings": {"transcribe": {"current_binding": "option+space", "id": "transcribe"}, "cancel": {"current_binding": "escape"}}}}' >"$store"
}

@test "a missing store gets the Nix-owned keys" {
  apply

  holds '. == {"settings": {"selected_model": "whisper-large-v3-turbo", "bindings": {"transcribe": {"current_binding": "option_right"}}}}'
}

@test "the Nix-owned keys replace what Handy stored" {
  a_store_handy_wrote

  apply

  holds '.settings.selected_model == "whisper-large-v3-turbo"'
  holds '.settings.bindings.transcribe.current_binding == "option_right"'
}

@test "every other key stays as Handy wrote it" {
  a_store_handy_wrote

  apply

  holds '.settings.post_process_api_keys.openai == "sk-x"'
  holds '.settings.bindings.transcribe.id == "transcribe"'
  holds '.settings.bindings.cancel.current_binding == "escape"'
}

@test "applying twice leaves the same file as applying once" {
  a_store_handy_wrote
  apply
  cp "$store" "$BATS_TEST_TMPDIR/once.json"

  apply

  cmp "$store" "$BATS_TEST_TMPDIR/once.json"
}

@test "no temp file is left beside the store" {
  apply

  run ls "$(dirname "$store")"
  [ "$output" = settings_store.json ]
}
