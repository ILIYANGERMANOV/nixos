#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs
# The flake is a stub printing what `nix eval` of lib.factories prints.

load ../../programs/shell-check/test_helper

setup() {
  stub nix 'printf "software-factory hetzner\nsoftware-factory-lenovo thinkpad-t15p"'
}

@test "a factory prints its platform" {
  run bash "$BATS_TEST_DIRNAME/factory-host.sh" software-factory-lenovo

  [ "$status" -eq 0 ]
  [ "$output" = thinkpad-t15p ]
}

@test "an unknown host fails naming the factories" {
  run bash "$BATS_TEST_DIRNAME/factory-host.sh" lenovo-old

  [ "$status" -eq 1 ]
  [[ "$output" == *"'lenovo-old' is not a software factory"* ]]
  [[ "$output" == *"software-factory software-factory-lenovo"* ]]
}

@test "a prefix of a factory is not that factory" {
  run bash "$BATS_TEST_DIRNAME/factory-host.sh" software

  [ "$status" -eq 1 ]
}
