#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

@test "terminate: ends repository sessions, never the admin's, keeps servers running" {
  clone_repo origin
  wt=$(add_worktree origin clean)
  factory-ctl start origin
  start_session "$wt"
  repo_session=$!
  mkdir -p "$HOME/admin"
  start_session "$HOME/admin"
  admin_session=$!

  factory-ctl terminate

  ended "$repo_session" || fail "the repository session survived"
  alive "$admin_session" || fail "the admin session was ended"
  active origin || fail "the server was stopped"
  factory-ctl terminate >"$work/out"
  grep -q "No live sessions" "$work/out" || fail "terminate with nothing to end"
}

@test "terminate: exits 2 when a session has local work; --force ends it" {
  clone_repo origin
  wt=$(add_worktree origin busy)
  touch "$wt/new-file"
  start_session "$wt"
  session=$!

  run -2 factory-ctl terminate origin
  alive "$session" || fail "a refused terminate ended the session"

  factory-ctl terminate --force origin
  ended "$session" || fail "--force did not end the session"
  [ -e "$wt/new-file" ] || fail "terminate deleted work"
}
