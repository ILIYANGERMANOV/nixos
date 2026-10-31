#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it
# factory-relink-skills (default.nix), factory-link-skills (programs/skills-link)
# and what `factory-ctl status` reports about them. Some tests race a reader
# against the writers, which pins that a relink updates ~/.claude/skills in
# place; each has its own world and its own reader.

load test_helper

skills="$HOME/.claude/skills"

# Two farms holding the same skill, as two generations do.
setup() {
  fresh_world
  mkdir -p "$skills" "$work/farm-a/alpha" "$work/farm-a/beta" "$work/farm-b/alpha"
}

status_reports() {
  factory-ctl status >"$work/out"
  grep -qxF "$1" "$work/out" || fail_showing "$work/out" "status does not report: $1"
}

@test "factory-relink-skills: replaces links a GC left dangling; status counts them, then none" {
  ln -s "$work/collected/alpha" "$skills/alpha"
  ln -s "$work/collected/gamma" "$skills/gamma"
  ln -s "$work/farm-a/beta" "$skills/beta"
  status_reports "Skills: 2 dangling link(s): alpha gamma"

  factory-relink-skills "$work/farm-a"

  [ "$(readlink "$skills/alpha")" = "$work/farm-a/alpha" ] || fail "alpha was not relinked"
  [ ! -L "$skills/gamma" ] || fail "a link of the old farm survived"
  status_reports "Skills: 0 dangling links"
}

@test "factory-relink-skills: works on a first run with no ~/.claude" {
  rm -rf "${HOME:?}/.claude"

  factory-relink-skills "$work/farm-a"

  [ "$(readlink "$skills/beta")" = "$work/farm-a/beta" ] || fail "the first run linked nothing"
}

# Flags the skill as missing whenever it sees that, until the test ends.
watch_skill() {
  while true; do
    [ -e "$skills/alpha" ] || touch "$work/skill-missing"
  done
}

@test "factory-relink-skills: a skill never goes missing while it swaps farms" {
  factory-relink-skills "$work/farm-a"
  in_background watch_skill
  reader=$!

  for _ in $(seq 40); do
    factory-relink-skills "$work/farm-b"
    factory-relink-skills "$work/farm-a"
  done

  alive "$reader" || fail "the reader died"
  stop_background
  [ ! -e "$work/skill-missing" ] || fail "a reader saw the skill missing during a relink"
}

# Flags the directory as empty whenever it sees that, until the test ends.
watch_listing() {
  while true; do
    [ -n "$(ls -A "$skills")" ] || touch "$work/skills-empty"
  done
}

@test "factory-link-skills: overlapping runs all succeed, and a reader never sees none" {
  factory-link-skills "$work/farm-a"
  in_background watch_listing
  reader=$!

  (
    for _ in $(seq 200); do
      { factory-link-skills "$work/farm-a" || touch "$work/link-failed"; } 2>/dev/null &
      { factory-link-skills "$work/farm-b" || touch "$work/link-failed"; } 2>/dev/null &
    done
    wait
  )

  alive "$reader" || fail "the reader died"
  stop_background
  [ ! -e "$work/link-failed" ] || fail "a link run aborted while another ran"
  [ ! -e "$work/skills-empty" ] || fail "a reader saw ~/.claude/skills empty"
  [ -z "$(find "$HOME/.claude" -maxdepth 1 -name '.skills.??????')" ] || fail "a scratch directory was left behind"
}

@test "factory-link-skills: a reader holding the directory open still lists every skill" {
  factory-link-skills "$work/farm-a"
  exec 7<"$skills"

  factory-link-skills "$work/farm-b"
  factory-link-skills "$work/farm-a"

  [ -n "$(ls -A /proc/self/fd/7/ 2>/dev/null)" ] || fail "a relink emptied a directory a reader had open"
  exec 7<&-
}

@test "factory-link-skills: keeps the directory Claude Code syncs skills into" {
  mkdir -p "$skills/synced/remote-skill"

  factory-link-skills "$work/farm-a"
  factory-link-skills "$work/farm-b"

  [ -d "$skills/synced/remote-skill" ] || fail "a relink deleted the synced skills"
}

@test "factory-relink-skills: waits for the lock, and gives up without failing" {
  factory-relink-skills "$work/farm-a"
  exec 8>"$HOME/.claude/.factory.lock"
  flock 8

  factory-relink-skills "$work/farm-b" 2>"$work/out"
  exec 8>&-

  grep -q "left ~/.claude/skills as it was" "$work/out" || fail "the skipped relink says nothing"
  [ "$(readlink "$skills/alpha")" = "$work/farm-a/alpha" ] || fail "relinked without holding the lock"
  factory-relink-skills "$work/farm-b"
  [ "$(readlink "$skills/alpha")" = "$work/farm-b/alpha" ] || fail "did not relink once the lock was free"
}
