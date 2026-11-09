#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  git init -q "$WORK/my-repo"
  mkdir -p "$WORK/my-repo/sub" "$WORK/not-a-repo"
  # caffeinate runs its command after its flags, as the real one does.
  stub caffeinate 'echo "caffeinate $*"; while [[ $1 == -* ]]; do shift; done; exec "$@"'
  stub claude-pm 'echo "claude-pm ran in $(pwd -P)"'
  on_ac_power
  stub ssh 'echo "Hi! You have successfully authenticated, but GitHub does not provide shell access." >&2; exit 1'
}

on_ac_power() {
  stub pmset 'printf "%s\n" "Now drawing from '\''AC Power'\''" " -InternalBattery-0 (id=1)	84%; charging; present: true"'
}

on_battery() {
  stub pmset 'printf "%s\n" "Now drawing from '\''Battery Power'\''" " -InternalBattery-0 (id=1)	84%; discharging; present: true"'
}

temp_factory() { bash -euo pipefail "$BATS_TEST_DIRNAME/temp-factory.sh" "$@"; }

# The first line of output: what caffeinate was exec'd with.
assert_serves_my_repo_with_capacity() {
  [ "${lines[0]}" = "caffeinate -i -s claude-pm remote-control --name my-repo --spawn worktree --capacity $1 --no-create-session-in-dir --permission-mode auto" ]
}

@test "in a repo it serves it through caffeinate -i -s with worktrees and capacity 4" {
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory

  [ "$status" -eq 0 ]
  assert_serves_my_repo_with_capacity 4
}

@test "claude runs at the repo root even when started in a subdirectory" {
  root=$(cd "$WORK/my-repo" && pwd -P)
  cd "$WORK/my-repo/sub"

  run --separate-stderr temp_factory

  [ "${lines[1]}" = "claude-pm ran in $root" ]
}

@test "a dir argument picks the repo instead of the current directory" {
  cd "$WORK/not-a-repo"

  run --separate-stderr temp_factory "$WORK/my-repo/sub"

  [ "$status" -eq 0 ]
  assert_serves_my_repo_with_capacity 4
}

@test "--capacity passes its number through" {
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory --capacity 7

  assert_serves_my_repo_with_capacity 7
}

@test "--capacity without a positive number is refused and starts nothing" {
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory --capacity zero

  [ "$status" -eq 2 ]
  [ "$output" = "" ]
}

@test "outside a git repo it refuses and starts nothing" {
  cd "$WORK/not-a-repo"

  run --separate-stderr temp_factory

  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ $stderr == *"not inside a git repository"* ]]
}

@test "on battery it warns and still starts" {
  on_battery
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory

  [ "$status" -eq 0 ]
  [[ $stderr == *"warning: on battery"*"drain the battery"*"caffeinate -s only"*"on AC power"* ]]
  assert_serves_my_repo_with_capacity 4
}

@test "on AC power there is no battery warning" {
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory

  [[ $stderr != *"battery"* ]]
}

@test "an ssh login that GitHub confirms starts even though ssh exits 1" {
  stub ssh 'echo "Hi user! You'\''ve successfully authenticated, but GitHub does not provide shell access." >&2; exit 1'
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory

  [ "$status" -eq 0 ]
  assert_serves_my_repo_with_capacity 4
}

@test "an ssh exit 1 without GitHub's greeting aborts before caffeinate, naming the YubiKey" {
  stub ssh 'echo "git@github.com: Permission denied (publickey)." >&2; exit 1'
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory

  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ $stderr == *"Permission denied (publickey)."*"Plug in your YubiKey"* ]]
}

@test "an ssh that cannot connect aborts before caffeinate, naming the YubiKey" {
  stub ssh 'echo "ssh: connect to host github.com port 22: Network is unreachable" >&2; exit 255'
  cd "$WORK/my-repo"

  run --separate-stderr temp_factory

  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ $stderr == *"Network is unreachable"*"Plug in your YubiKey"* ]]
}
