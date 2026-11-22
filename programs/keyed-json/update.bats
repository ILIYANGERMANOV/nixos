#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2312 # jq filters are single-quoted on purpose, and a masked failure fails the assertion around it

load ../shell-check/test_helper

setup() {
  file="$BATS_TEST_TMPDIR/app/config.json"
  values="$BATS_TEST_TMPDIR/values.json"
  echo '{"a": 1}' >"$values"
}

update() { bash -euo pipefail "$BATS_TEST_DIRNAME/update.sh" "$file" "${1:-.owned = \$nix[0]}" "$values"; }

a_file_the_tool_wrote() {
  mkdir -p "$(dirname "$file")"
  echo '{"owned": {"old": true}, "theirs": "kept"}' >"$file"
}

@test "a missing file and its directory are created with the keys" {
  update

  [ "$(jq -c . "$file")" = '{"owned":{"a":1}}' ]
}

@test "the filter's keys change and every other key stays" {
  a_file_the_tool_wrote

  update

  [ "$(jq -cS . "$file")" = '{"owned":{"a":1},"theirs":"kept"}' ]
}

@test "a file that is not JSON stops the update, untouched and with no temp file" {
  mkdir -p "$(dirname "$file")"
  echo 'not json' >"$file"

  run --separate-stderr update

  [ "$status" -ne 0 ]
  [ "$(cat "$file")" = "not json" ]
  run ls "$(dirname "$file")"
  [ "$output" = config.json ]
}

@test "no temp file is left beside the file" {
  update

  run ls "$(dirname "$file")"
  [ "$output" = config.json ]
}
