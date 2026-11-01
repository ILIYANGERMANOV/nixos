#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2119,SC2120,SC2312 # a stub's body expands when the stub runs, not every test passes arguments, and a masked failure fails the assertion around it

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR" askpass=/nix/store/askpass
  export openssh="$WORK/bin/ssh"
  unset DISPLAY
}

ssh_wrapper() { bash -euo pipefail "$BATS_TEST_DIRNAME/ssh.sh" "$@"; }

@test "ssh gets the askpass helper and its arguments" {
  stub ssh 'echo "$SSH_ASKPASS $*"'

  run --separate-stderr ssh_wrapper -p 22 git@example.com

  [ "$output" = "/nix/store/askpass -p 22 git@example.com" ]
}

@test "ssh gets a DISPLAY, or askpass would never be used" {
  stub ssh 'echo "$DISPLAY"'

  run --separate-stderr ssh_wrapper

  [ "$output" = ":0" ]
}

@test "a DISPLAY already set wins" {
  stub ssh 'echo "$DISPLAY"'

  DISPLAY=:5 run --separate-stderr ssh_wrapper

  [ "$output" = ":5" ]
}

@test "ssh's stderr is a pipe even when ours is not, so it takes the askpass branch" {
  stub ssh '[ ! -p /dev/stderr ] || touch "$WORK/stderr-is-a-pipe"'

  ssh_wrapper 2>"$WORK/stderr"

  [ -e "$WORK/stderr-is-a-pipe" ]
}

@test "stdout and stderr each still reach their own stream" {
  stub ssh 'echo to-stdout; echo to-stderr >&2'

  run --separate-stderr ssh_wrapper

  [ "$output" = to-stdout ]
  [ "$stderr" = to-stderr ]
}

@test "ssh's exit code comes back through the pipe" {
  stub ssh 'exit 7'

  run --separate-stderr ssh_wrapper

  [ "$status" -eq 7 ]
}
