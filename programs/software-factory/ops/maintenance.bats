#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

setup() {
  fresh_world
  given_two_systems
}

# Whether Nix still counts the link $1 as a GC root.
registered() {
  local link
  for link in "$work/gcroots/auto"/*; do
    [ "$(readlink "$link")" != "$1" ] || return 0
  done
  return 1
}

@test "factory-maintenance rollback: switches to the previous generation" {
  ln -sfn "$work/systems/new" "$work/profiles/system"

  factory-maintenance rollback

  called "old switch"
  [ "$(jq -r '.op + " " + .state' "$work/ops/last.json")" = "rollback success" ] || fail "rollback not recorded"
}

@test "factory-maintenance gc: keeps two generations of the system profile, drops stale GC roots" {
  add_roots

  factory-maintenance gc

  called "nix-env -p $work/profiles/system --delete-generations +2"
  called "nix-store --gc"
  kept_what_must_stay
  { ! registered "$old_tmp_root" && ! registered "$old_cache_root" && ! registered "$spaced_root"; } || fail "a stale GC root is still registered"
  { registered "$new_tmp_root" && registered "$worktree_root" && registered "$shell_root"; } || fail "a GC root that must stay was unregistered"
  jq -r .message "$work/ops/last.json" >"$work/out"
  reports_freed_gb
}

@test "factory-maintenance gc: keeps two generations of a profile under the homes directory, by its unnumbered name" {
  mkdir -p "$HOME/.local/state/nix/profiles"
  ln -s "$work/systems/old" "$HOME/.local/state/nix/profiles/home-manager"
  ln -s "$work/systems/old" "$HOME/.local/state/nix/profiles/home-manager-1-link"

  factory-maintenance gc

  called "nix-env -p $HOME/.local/state/nix/profiles/home-manager --delete-generations +2"
  not_called "home-manager-1-link"
}

@test "factory-maintenance gc: runs a home's profile operations as its owner, so a path planted there gains no rights" {
  profiles="$HOME/.local/state/nix/profiles"
  mkdir -p "$profiles"
  ln -s "$work/systems/old" "$profiles/home-manager"
  echo intact >"$work/root-only"
  ln -s "$work/root-only" "$profiles/home-manager.lock"

  factory-maintenance gc

  owner="--reuid=$(id -u) --regid=$(id -g) --clear-groups --"
  called "setpriv $owner nix-env -p $profiles/home-manager --delete-generations +2"
  [ "$(cat "$work/root-only")" = intact ] || fail "a profile operation wrote through a path in the home"
  not_called "setpriv $owner nix-env -p $work/profiles/system"
}

@test "factory-maintenance gc: fails and collects nothing when it cannot list a profile as its owner" {
  mkdir -p "$HOME/.local/state/nix/profiles"
  ln -s "$work/systems/old" "$HOME/.local/state/nix/profiles/home-manager"
  touch "$GH/setpriv-fails"

  run -1 factory-maintenance gc

  [ "$(jq -r '.op + " " + .state' "$work/ops/last.json")" = "gc failure" ] || fail "the failure was not recorded"
  not_called "nix-store --gc"
}

@test "factory-maintenance reboot: refused within 10 minutes of boot" {
  echo '599.99 1000.00' >"$work/uptime"

  run -1 factory-maintenance reboot

  not_called "systemctl reboot"
  [ "$(jq -r '.op + " " + .state' "$work/ops/last.json")" = "reboot failure" ] || fail "the refusal was not recorded"
}

@test "factory-maintenance reboot: runs once 10 minutes have passed" {
  echo '600.00 1000.00' >"$work/uptime"

  factory-maintenance reboot

  called "systemctl reboot"
}
