#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs
# The repl's GHC wrapper, with ghc stubbed to print its arguments.

load ../shell-check/test_helper.bash

@test "ghc runs with its heap capped, the caller's arguments after the cap" {
  stub ghc 'echo "$*"'
  run bash "$BATS_TEST_DIRNAME/ghc-capped.sh" --interactive -e 'main'
  [ "$status" -eq 0 ]
  [ "$output" = '+RTS -M12g -RTS --interactive -e main' ]
}
