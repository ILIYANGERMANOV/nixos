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
  grep -Eq "$freed_gb" "$work/out" || fail "gc does not report the space freed in GB"
}

@test "factory-maintenance gc: keeps two generations of a profile under the homes directory, by its unnumbered name" {
  mkdir -p "$HOME/.local/state/nix/profiles"
  ln -s "$work/systems/old" "$HOME/.local/state/nix/profiles/home-manager"
  ln -s "$work/systems/old" "$HOME/.local/state/nix/profiles/home-manager-1-link"

  factory-maintenance gc

  called "nix-env -p $HOME/.local/state/nix/profiles/home-manager --delete-generations +2"
  not_called "home-manager-1-link"
}

# The gate reads the real /proc/uptime, which a sandbox cannot set, so this pins
# whichever side of it the build machine is on.
@test "factory-maintenance reboot: refused within 10 minutes of boot" {
  if [ "$(cut -d . -f 1 /proc/uptime)" -lt 600 ]; then
    run -1 factory-maintenance reboot
    not_called "systemctl reboot"
  else
    factory-maintenance reboot
    called "systemctl reboot"
  fi
}
