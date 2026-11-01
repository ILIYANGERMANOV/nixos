#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

@test "status: one row per server, then the last root operation and token warning" {
  clone_repo origin
  wt=$(add_worktree origin dirty)
  touch "$wt/new-file"
  factory-ctl start origin
  clone_repo parked
  mkdir -p "$work/ops"
  jq -n '{op: "deploy", state: "success", sha: "abcdef1234567", message: "Deployed", at: "now"}' >"$work/ops/last.json"
  date -d '+5 days' '+%F %T UTC' >"$work/ops/token-expires"

  factory-ctl status >"$work/out"

  grep -Eq '^admin +inactive +0 session' "$work/out" || fail "no admin row"
  grep -Eq '^origin +on +0 session.*1 worktree' "$work/out" || fail "origin's row is wrong"
  grep -Eq '^parked +off ' "$work/out" || fail "parked's row is wrong"
  grep -q 'Last deploy: success abcdef1' "$work/out" || fail "the last deploy is missing"
  grep -q 'WARNING: the deploy token expires' "$work/out" || fail "no expiry warning"
}

@test "stats: reports RAM, disk, CPU and uptime" {
  factory-ctl stats >"$work/out"

  { grep -q '^RAM ' "$work/out" && grep -q '^Disk ' "$work/out" && grep -q '^CPU ' "$work/out" && grep -Eq '^Up +[0-9]+d' "$work/out"; } ||
    fail_showing "$work/out" "stats is missing a line"
}
