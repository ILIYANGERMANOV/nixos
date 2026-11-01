#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

@test "deploy: dispatches the workflow on main and waits for it" {
  factory-ctl deploy

  called "gh workflow run deploy-factory.yml --repo owner/nixos --ref main"
  called "gh run watch 42 --repo owner/nixos --exit-status"
}

@test "deploy: a failed run exits 1 and links it" {
  touch "$GH/run-fails"

  run -1 factory-ctl deploy

  grep -q "actions/runs/42" <<<"$output" || fail "a failed request gave no link"
}

@test "rollback: starts its fixed root unit" {
  factory-ctl rollback

  called "systemctl start --no-block factory-rollback.service"
}

@test "reboot: starts its fixed root unit" {
  factory-ctl reboot

  called "systemctl start --no-block factory-reboot.service"
}

@test "gc: starts its fixed root unit" {
  factory-ctl gc

  called "systemctl start --no-block factory-gc.service"
}
