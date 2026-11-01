#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

setup() {
  fresh_world
  given_two_systems
}

posted_states() { [ "$(posted)" = "$1" ] || fail "posted $(posted)"; }
posted() { jq -s -r 'map(.state) | join(" ")' "$GH/posted"; }

@test "factory-deploy: nothing pending is a no-op" {
  echo '[]' >"$GH/deployments.json"

  factory-deploy

  not_called "nix "
}

@test "factory-deploy: a deployment with a status is not pending" {
  echo '[{"state": "success"}]' >"$GH/statuses.json"

  factory-deploy

  not_called "nix "
}

@test "factory-deploy: a failed read of a deployment's statuses waits for the next tick" {
  rm "$GH/statuses.json"

  factory-deploy

  not_called "nix "
}

@test "factory-deploy: an unreadable answer about a deployment's statuses waits for the next tick" {
  echo 'not json' >"$GH/statuses.json"

  factory-deploy

  not_called "nix "
}

@test "factory-deploy: builds the tip of main, tests it, then makes it the boot default" {
  factory-deploy

  called "nix build --no-link --print-out-paths github:owner/nixos/abc123#nixosConfigurations.software-factory.config.system.build.toplevel"
  called "new test"
  called "new boot"
  [ "$(readlink "$work/profiles/system")" = "$work/systems/new" ] || fail "the profile was not set"
  posted_states "in_progress success"
  [ "$(jq -r .state "$work/ops/last.json")" = success ] || fail "the result was not recorded"
  grep -q 2027-01-01 "$work/ops/token-expires" || fail "the token expiry was not recorded"
}

@test "factory-deploy: the token travels in curl's config, never in argv" {
  factory-deploy

  grep -q 'github_pat_secret' "$GH/config" || fail "the token was not sent"
  ! grep -q 'github_pat_secret' "$CALLS" || fail "the token appeared in argv"
}

@test "factory-deploy: refuses anything but the tip of main, so an older commit of it cannot be deployed" {
  echo '{"sha": "def456"}' >"$GH/main.json"

  run -1 factory-deploy

  not_called "nix build"
  posted_states "in_progress failure"
}

@test "factory-deploy: a failed build changes nothing" {
  touch "$GH/build-fails"

  run -1 factory-deploy

  not_called "new test"
  posted_states "in_progress failure"
}

went_back_to_the_old_system() {
  called "new test"
  called "old test"
  not_called "new boot"
  [ "$(readlink "$work/profiles/system")" = "$work/systems/old" ] || fail "the boot default moved"
  grep -q "rolled back" "$work/ops/last.json" || fail "the rollback was not recorded"
}

@test "factory-deploy: a failed health gate goes back to the old system: sshd down" {
  export SSHD_UP=0

  run -1 factory-deploy

  went_back_to_the_old_system
}

@test "factory-deploy: a failed health gate goes back to the old system: GitHub unreachable" {
  touch "$GH/github-down"

  run -1 factory-deploy

  went_back_to_the_old_system
}

@test "factory-deploy: the running system is not switched again" {
  ln -sfn "$work/systems/new" "$work/current-system"

  factory-deploy

  not_called "new test"
  posted_states "in_progress success"
}

@test "factory-deploy: with GitHub refusing every POST, gives up after one failure report and leaves no temporary directory" {
  mkdir "$work/deploy-tmp"
  touch "$GH/post-fails"

  ! TMPDIR="$work/deploy-tmp" timeout 30 factory-deploy >/dev/null 2>&1 || fail "the failed POST did not fail the deploy"

  [ "$(grep -c -- '-X POST' "$CALLS")" -le 3 ] || fail "the failure report repeated without end"
  [ -z "$(ls -A "$work/deploy-tmp")" ] || fail "left behind: $(ls -A "$work/deploy-tmp")"
}
