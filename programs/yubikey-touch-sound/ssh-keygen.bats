#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export beep=beep openssh_keygen=ssh-keygen
  # Noisy on the streams it must stay off, and it stops only when told to.
  stub beep 'trap "kill \$!; touch \"\$WORK/beep-stopped\"; exit 0" TERM
    echo alert
    echo alert >&2
    cat
    touch "$WORK/beep-started"
    sleep 30 &
    wait'
}

keygen() { bash -euo pipefail "$BATS_TEST_DIRNAME/ssh-keygen.sh" "$@"; }

# Signing waits for the alert to be up; anything else takes long enough for a
# stray one to show.
signer() { stub ssh-keygen "wait_for \"\$WORK/beep-started\"; $1"; }
verifier() { stub ssh-keygen "sleep 0.2; $1"; }

@test "signing alerts until the signer is done" {
  signer ':'

  keygen -Y sign -n git -f key

  wait_for "$WORK/beep-stopped"
}

@test "signing streams the payload to the signer and only its signature to stdout" {
  signer 'printf "signed %s" "$(cat)"'

  signature=$(printf payload | keygen -Y sign -n git -f key)

  [ "$signature" = "signed payload" ]
}

@test "signing hands back the signer's exit code" {
  signer 'exit 3'

  run keygen -Y sign -n git -f key

  [ "$status" -eq 3 ]
}

@test "verifying passes through, silent, with its arguments and exit code" {
  verifier 'echo "verified $*"; exit 4'

  run keygen -Y verify -n git -s sig

  [ "$status" -eq 4 ]
  [ "$output" = "verified -Y verify -n git -s sig" ]
  [ ! -e "$WORK/beep-started" ]
}

@test "the word sign anywhere but after -Y is not signing" {
  verifier ':'

  run keygen -Y verify -n sign

  [ "$status" -eq 0 ]
  [ ! -e "$WORK/beep-started" ]
}
