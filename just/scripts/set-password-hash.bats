#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2119,SC2120,SC2312 # a stub's body expands when the stub runs, not every test passes arguments, and a masked failure fails the assertion around it
# Only what stands between bad input and the secrets file. Nothing here says how
# the file is seeded.

load ../../programs/shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  cd "$WORK" || return
  touch age-key
  stub sudo 'case "$*" in
    "-n test -f "*) [ -e "$WORK/age-key" ] ;;
    *) ;;
  esac'
  stub mkpasswd 'cat >/dev/null; echo "\$y\$hash"'
  stub sops 'cat >>"$WORK/sops-stdin"
    echo "$*" >>"$WORK/sops-calls"'
}

# Answers the prompt and its repeat.
set_password() { printf '%s\n' "$2" "$3" | bash "$BATS_TEST_DIRNAME/set-password-hash.sh" "$1"; }

@test "matching passwords write the hash, off argv" {
  run set_password lenovo-old hunter2 hunter2

  [ "$status" -eq 0 ]
  grep -qxF 'set --value-stdin secrets/hosts/lenovo-old.yaml ["password-hash"]' "$WORK/sops-calls"
  grep -qF '"$y$hash"' "$WORK/sops-stdin"
}

@test "a host that could escape secrets/hosts is refused" {
  run set_password ../evil hunter2 hunter2

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid host name '../evil'"* ]]
  [ ! -e "$WORK/sops-calls" ]
}

@test "a host with a capital is refused" {
  run set_password Lenovo hunter2 hunter2

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid host name"* ]]
  [ ! -e "$WORK/sops-calls" ]
}

@test "an empty host is refused" {
  run set_password "" hunter2 hunter2

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid host name"* ]]
  [ ! -e "$WORK/sops-calls" ]
}

@test "no age key stops it before any prompt" {
  rm age-key

  run set_password lenovo-old hunter2 hunter2

  [ "$status" -eq 1 ]
  [[ "$output" == *"no age key"* ]]
  [ ! -e "$WORK/sops-calls" ]
}

@test "an empty password is refused" {
  run set_password lenovo-old "" ""

  [ "$status" -eq 1 ]
  [[ "$output" == *"empty password"* ]]
  [ ! -e "$WORK/sops-calls" ]
}

@test "passwords that differ are refused" {
  run set_password lenovo-old hunter2 hunter3

  [ "$status" -eq 1 ]
  [[ "$output" == *"passwords do not match"* ]]
  [ ! -e "$WORK/sops-calls" ]
}
