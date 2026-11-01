#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

@test "start: clones a URL under its name, enables and starts it" {
  factory-ctl start "file://$work/origin.git"

  [ -d "$HOME/repos/origin/.git" ] || fail "origin was not cloned"
  active origin || fail "origin was not started"
  enabled origin || fail "origin was not enabled"
}

@test "start: rerunning is a no-op" {
  factory-ctl start "file://$work/origin.git"
  touch "$HOME/repos/origin/marker"

  factory-ctl start "file://$work/origin.git"

  [ -e "$HOME/repos/origin/marker" ] || fail "an existing clone was replaced"
  [ "$(grep -c . "$HOME/.local/state/factory/enabled")" -eq 1 ] || fail "origin was enabled twice"
}

@test "start: derives the name from ssh and https URLs; an explicit name wins" {
  mkdir -p "$HOME/repos/repo" "$HOME/repos/other" "$HOME/repos/custom"

  factory-ctl start git@github.com:owner/repo.git
  factory-ctl start https://github.com/owner/other
  factory-ctl start "file://$work/origin.git" custom

  { active repo && active other && active custom; } || fail "a URL was mapped to the wrong name"
}

@test "start: a bare name serves its clone" {
  clone_repo origin

  factory-ctl start origin

  active origin || fail "the clone was not started"
}

@test "start: a bare name exits 3 when there is no clone" {
  run -3 factory-ctl start missing

  ! active missing || fail "started a repository that is not cloned"
  ! enabled missing || fail "enabled a repository that is not cloned"
}

@test "start / stop: refuse unsafe names" {
  # shellcheck disable=SC2016 # a literal dollar in a name
  for bad in ".hidden" ".." "a b" 'a$b'; do
    run -1 factory-ctl start "$bad"
    run -1 factory-ctl stop "$bad"
  done
  run -1 factory-ctl start "file://$work/.git"

  [ ! -s "$CALLS" ] || fail "a unit was touched for an unsafe name"
}

@test "stop: stops and disables a repository with nothing at risk" {
  clone_repo origin
  add_worktree origin pushed
  factory-ctl start origin

  factory-ctl stop origin

  ! active origin || fail "origin still runs"
  ! enabled origin || fail "origin would start at boot"
}

@test "stop: stopping twice succeeds" {
  clone_repo origin
  factory-ctl start origin
  factory-ctl stop origin

  factory-ctl stop origin || fail "stopping twice failed"
}

# Given a repository at risk, stop refuses and changes nothing; --force stops it.
stop_refuses_until_forced() {
  factory-ctl start origin

  run -2 factory-ctl stop origin
  grep -q "origin" <<<"$output" || fail "the refusal did not say what is at risk"
  { active origin && enabled origin; } || fail "a refused stop changed state"

  factory-ctl stop --force origin
  ! active origin || fail "--force did not stop"
  ! enabled origin || fail "--force did not disable"
}

@test "stop: exits 2 on a live session; --force stops" {
  clone_repo origin
  wt=$(add_worktree origin work)
  start_session "$wt"

  stop_refuses_until_forced
}

@test "stop: exits 2 on uncommitted work; --force stops" {
  clone_repo origin
  wt=$(add_worktree origin work)
  touch "$wt/new-file"

  stop_refuses_until_forced
}

@test "stop: exits 2 on unpushed work; --force stops" {
  clone_repo origin
  wt=$(add_worktree origin work)
  git -C "$wt" commit --quiet --allow-empty -m local

  stop_refuses_until_forced
}

@test "stop: exits 2 on a worktree that lost its .git; --force stops" {
  clone_repo origin
  wt=$(add_worktree origin work)
  rm "$wt/.git"

  stop_refuses_until_forced
}

@test "restart: restarts an enabled repository" {
  clone_repo origin
  factory-ctl start origin

  factory-ctl restart origin

  called "systemctl --user restart claude-rc@origin.service"
}

@test "restart: refuses a repository that is off" {
  clone_repo origin

  run -1 factory-ctl restart origin
}

given_bot_repos() {
  echo '[{"name":"Deslop","ssh_url":"git@github.com:a/Deslop.git"},{"name":"deslop","ssh_url":"git@github.com:b/deslop.git"},{"name":"x","ssh_url":"git@github.com:a/x.git"}]' >"$GH/user-repos.json"
}

@test "resolve: finds the bot's repositories by name, case-insensitively" {
  given_bot_repos

  factory-ctl resolve deslop >"$work/out"

  [ "$(wc -l <"$work/out")" -eq 2 ] || fail "resolve missed a match"
}

@test "resolve: exits 1 when no repository matches" {
  given_bot_repos

  run -1 factory-ctl resolve nothing
}

@test "boot: adopts existing clones once, bootstraps declared repos, survives a failure" {
  clone_repo by-hand

  run -1 factory-boot

  [ -d "$HOME/repos/declared/.git" ] || fail "the declared repo was not cloned"
  { active declared && active by-hand; } || fail "boot did not start every enabled repo"
  not_called "claude-rc@unreachable"
  ! enabled unreachable || fail "a repo that failed to clone was enabled"
}

@test "boot: a stopped repository stays stopped, declared or not" {
  clone_repo by-hand
  run -1 factory-boot
  factory-ctl stop declared
  factory-ctl stop by-hand
  rm -rf "${UNITS:?}"

  run -1 factory-boot

  ! active declared || fail "boot restarted a stopped declared repo"
  ! active by-hand || fail "boot restarted a stopped repo"
}
