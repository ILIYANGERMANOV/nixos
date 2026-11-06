#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export beep=beep openssh_keygen=ssh-keygen no_touch_signing=0
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

@test "signing keeps the alert off stderr" {
  signer ':'

  keygen -Y sign -n git -f key 2>"$WORK/stderr"

  [ ! -s "$WORK/stderr" ]
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

# A key stub pair in a stand-in ~/.ssh.
key_pair() {
  mkdir -p "$WORK/ssh"
  echo stub >"$WORK/ssh/key"
  echo pub >"$WORK/ssh/key.pub"
}

# -p appends "flipped" to the stub and chats on stdout like the real one; a
# sign prints the stub it signs with ($6 after `-Y sign -n git -f`) and the
# directory it lives in, then waits long enough for a stray alert to show.
no_touch_signer() {
  no_touch_signing=1
  stub ssh-keygen 'case "$1" in
    -p) echo saved; echo flipped >>"${@: -1}" ;;
    -Y) dirname "$6" >"$WORK/sign-dir"
      sleep 0.2
      cat "${6%.pub}"
      '"$1"' ;;
  esac'
}

@test "no-touch signing signs with a flipped copy and only its signature on stdout" {
  key_pair
  no_touch_signer ':'

  signature=$(keygen -Y sign -n git -f "$WORK/ssh/key.pub")

  [ "$signature" = "$(printf 'stub\nflipped')" ]
}

@test "no-touch signing leaves the key stub untouched and removes the copy" {
  key_pair
  no_touch_signer ':'

  keygen -Y sign -n git -f "$WORK/ssh/key.pub"

  grep -qx stub "$WORK/ssh/key"
  read -r copy <"$WORK/sign-dir"
  [ ! -e "$copy" ]
}

@test "no-touch signing does not alert" {
  key_pair
  no_touch_signer ':'

  keygen -Y sign -n git -f "$WORK/ssh/key.pub"

  [ ! -e "$WORK/beep-started" ]
}

@test "no-touch signing hands back the signer's exit code" {
  key_pair
  no_touch_signer 'exit 3'

  run keygen -Y sign -n git -f "$WORK/ssh/key.pub"

  [ "$status" -eq 3 ]
}

@test "no-touch signing fails naming the OpenSSH version when the flag cannot be cleared" {
  key_pair
  no_touch_signing=1
  stub ssh-keygen 'case "$1" in
    -p) exit 1 ;;
    -Y) touch "$WORK/signed" ;;
  esac'

  run keygen -Y sign -n git -f "$WORK/ssh/key.pub"

  [ "$status" -eq 1 ]
  [[ "$output" == *"OpenSSH >= 10.5p1"* ]]
  [ ! -e "$WORK/signed" ]
}
