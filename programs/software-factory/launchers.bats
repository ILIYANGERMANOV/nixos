#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it
# factory-rc and factory-rc-admin, built in default.nix: Remote Control's start,
# across ctl's paths and Claude's own files.

load test_helper

trusted() { [ "$(jq --arg dir "$1" '.projects[$dir].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ]; }

@test "factory-rc: applies the flavor, trusts the repo, starts Remote Control" {
  clone_repo origin
  echo '{"projects":{"/elsewhere":{"hasTrustDialogAccepted":true}}}' >"$HOME/.claude.json"
  printf 'ghp_check' >"$work/gh-token"

  factory-rc origin

  called "claude-factory --version"
  called "claude remote-control --name origin $repoArgs GH_TOKEN=ghp_check PWD=$HOME/repos/origin"
  trusted "$HOME/repos/origin" || fail "repo was not trusted"
  trusted /elsewhere || fail "trusting one repo lost another's trust"
  [ "$(jq '.remoteDialogSeen' "$HOME/.claude.json")" = true ] ||
    fail "Remote Control would wait on its first-run prompt"
}

@test "factory-rc: refuses a directory that is not a clone, and unsafe names" {
  mkdir -p "$HOME/repos/plain"

  run -1 factory-rc plain
  run ! factory-rc ""
  # shellcheck disable=SC2016 # a literal dollar in a name
  for bad in ".hidden" ".." "a b" "a/b" 'a$b'; do
    run -1 factory-rc "$bad"
  done

  [ ! -s "$CALLS" ] || fail "factory-rc ran Claude for a refused name"
}

@test "factory-rc-admin: serves ~/admin, one directory for every session" {
  printf 'ghp_check' >"$work/gh-token"

  factory-rc-admin

  called "claude remote-control --name admin $adminArgs GH_TOKEN=ghp_check PWD=$HOME/admin"
  trusted "$HOME/admin" || fail "the admin directory was not trusted"
  jq -e '.permissions.allow | index("Bash(factory-ctl *)")' "$adminSettings" >/dev/null ||
    fail "the admin agent is not allowed to run factory-ctl"
}
