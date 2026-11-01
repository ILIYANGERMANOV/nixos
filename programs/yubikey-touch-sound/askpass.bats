#!/usr/bin/env bats
# ssh reads what askpass prints as an answer, so a refusal must print nothing.

load ../shell-check/test_helper

setup() {
  export beep=beep
  stub beep 'echo beeping'
}

askpass() { bash -euo pipefail "$BATS_TEST_DIRNAME/askpass.sh" "$@"; }

@test "a touch request shows the notice and beeps" {
  run --separate-stderr askpass "Confirm user presence for key ED25519-SK SHA256:abc"

  [ "$status" -eq 0 ]
  [ "$output" = beeping ]
  [ "$stderr" = "Confirm user presence for key ED25519-SK SHA256:abc" ]
}

@test "a passphrase prompt is refused without an answer or a beep" {
  run --separate-stderr askpass "Enter passphrase for key '/home/me/.ssh/id':"

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"refusing unexpected prompt"* ]]
}

@test "a prompt that only contains the touch request is refused" {
  run --separate-stderr askpass "Password: Confirm user presence"

  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "no prompt at all is refused" {
  run --separate-stderr askpass

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"<empty>"* ]]
}
