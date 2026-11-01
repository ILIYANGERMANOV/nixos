#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

# check.nix builds factory-gc-on-pressure with a threshold of 10 percent free.
fake_df() {
  mkdir -p "$work/bin"
  printf '#!/bin/sh\n%s\n' "$1" >"$work/bin/df"
  chmod +x "$work/bin/df"
  PATH="$work/bin:$PATH"
}

@test "gc-on-pressure: below the threshold, starts the GC unit" {
  fake_df 'printf "Avail Size\n99 1000\n"'

  factory-gc-on-pressure

  called "systemctl start --no-block factory-gc.service"
}

@test "gc-on-pressure: at the threshold, leaves the disk alone" {
  fake_df 'printf "Avail Size\n100 1000\n"'

  factory-gc-on-pressure

  not_called factory-gc
}

@test "gc-on-pressure: a failed disk reading fails the run" {
  fake_df 'exit 1'

  run ! factory-gc-on-pressure

  not_called factory-gc
}
