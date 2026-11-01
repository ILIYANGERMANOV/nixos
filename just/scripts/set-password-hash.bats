#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs
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

# It failed saying $1, and the secrets file was never opened.
refused() {
  [ "$status" -eq 1 ]
  [[ "$output" == *"$1"* ]]
  [ ! -e "$WORK/sops-calls" ]
}

@test "matching passwords write the hash, off argv" {
  run set_password lenovo-old hunter2 hunter2

  [ "$status" -eq 0 ]
  grep -qxF 'set --value-stdin secrets/hosts/lenovo-old.yaml ["password-hash"]' "$WORK/sops-calls"
  grep -qF '"$y$hash"' "$WORK/sops-stdin"
}

@test "a host with a digit is accepted" {
  run set_password macos2 hunter2 hunter2

  [ "$status" -eq 0 ]
}

@test "a host that could escape secrets/hosts is refused" {
  run set_password ../evil hunter2 hunter2

  refused "invalid host name '../evil'"
}

@test "a host with a capital is refused" {
  run set_password Lenovo hunter2 hunter2

  refused "invalid host name"
}

@test "an empty host is refused" {
  run set_password "" hunter2 hunter2

  refused "invalid host name"
}

@test "no age key stops it before it reads a password" {
  rm age-key
  printf 'hunter2\nhunter2\n' >answers

  # A read moves the shared offset, and the prompt shows only on a terminal.
  {
    run bash "$BATS_TEST_DIRNAME/set-password-hash.sh" lenovo-old
    unread=$(cat)
  } <answers

  refused "no age key"
  [ "$unread" = $'hunter2\nhunter2' ]
}

@test "an empty password is refused" {
  run set_password lenovo-old "" ""

  refused "empty password"
}

@test "passwords that differ are refused" {
  run set_password lenovo-old hunter2 hunter3

  refused "passwords do not match"
}
