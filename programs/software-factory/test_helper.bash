# shellcheck shell=bash disable=SC2034,SC2154,SC2312 # check.nix sets $work, the suites read what this sets, and a masked failure fails the assertion around it
# What every suite shares: the world a test runs in, and its assertions. check.nix
# runs the suites with every program and double on PATH and $work, $repoArgs,
# $adminArgs and $adminSettings set. The programs have $work baked in, so suites
# cannot run in parallel; setup rebuilds it, so no test sees another's state.
#
# bats runs a test under `set -e`, which ignores a failed `! cmd`, so an assertion
# that something is false reads `! cmd || fail "..."`.

bats_require_minimum_version 1.5.0

export HOME="$work/home" CALLS="$work/calls" UNITS="$work/units" GH="$work/gh"
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.com
export GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.com

setup() { fresh_world; }
teardown() { stop_background; }

# origin.git has one commit on main.
fresh_world() {
  rm -rf "${work:?}"
  mkdir -p "$HOME" "$GH"
  : >"$CALLS"
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  git init --quiet --bare "$work/origin.git"
  git clone --quiet "$work/origin.git" "$work/seed" 2>/dev/null
  git -C "$work/seed" commit --quiet --allow-empty -m init
  git -C "$work/seed" push --quiet origin main
}

# ─── Assertions ──────────────────────────────────────────────────────────────

called() { grep -qxF "$1" "$CALLS" || fail_showing "$CALLS" "expected call: $1"; }
not_called() { ! grep -qF "$1" "$CALLS" || fail_showing "$CALLS" "unexpected call: $1"; }
active() { [ -e "$UNITS/claude-rc@$1.service" ]; }
enabled() { grep -qxF "$1" "$HOME/.local/state/factory/enabled" 2>/dev/null; }
# What a run printed to $work/out says how much space it freed.
reports_freed_gb() {
  grep -Eq '^Freed -?[0-9]+\.[0-9] GB$' "$work/out" || fail_showing "$work/out" "the space freed in GB is not reported"
}
# Fails with the file that explains why.
fail_showing() {
  cat "$1" >&2
  fail "$2"
}
fail() {
  echo "FAIL: $*" >&2
  return 1
}

# ─── Repositories ────────────────────────────────────────────────────────────

clone_repo() { git clone --quiet "$work/origin.git" "$HOME/repos/$1" 2>/dev/null; }
# A worktree of repository $1 named $2, on its own branch, pushed: at $3, or
# where a session makes one.
add_worktree() {
  local wt="${3:-$HOME/repos/$1/.claude/worktrees/$2}"
  git -C "$HOME/repos/$1" worktree add --quiet -b "$2" "$wt" 2>/dev/null
  git -C "$wt" push --quiet origin "$2" 2>/dev/null
  echo "$wt"
}

# ─── Processes ───────────────────────────────────────────────────────────────

# Background processes, stopped and reaped when the test ends, even a failed
# one, so none outlives its world. A process holding bats's fd 3 would hang the
# run until it exits.
background=()
in_background() {
  "$@" >/dev/null 2>&1 3>&- &
  background+=("$!")
}
stop_background() {
  [ "${#background[@]}" -eq 0 ] || {
    kill "${background[@]}" 2>/dev/null || true
    wait "${background[@]}" 2>/dev/null || true
  }
}
# A live session: a process with --sdk-url in its command line, working in $1.
start_session() { in_background run_session "$1"; }
run_session() { cd "$1" && exec bash -c 'sleep 300; true' session --sdk-url; }
# A signalled process dies shortly after the signal returns.
ended() {
  local _
  for _ in $(seq 100); do
    alive "$1" || return 0
    sleep 0.1
  done
  return 1
}
# A process that was killed stays a zombie until reaped, so check its state.
alive() { [ -e "/proc/$1" ] && [ "$(cut -d " " -f 3 "/proc/$1/stat")" != Z ]; }

# ─── GC roots ────────────────────────────────────────────────────────────────

# Result links of builds, registered as indirect GC roots the way Nix does.
# Stale: one in /tmp, one in a kept cache and one whose path has a space, all
# made three days ago. Kept: one in /tmp made now, a worktree's root in
# ~/.gcroots and a `nix develop --profile` generation link in ~/.cache, both
# made three days ago. Swapped: registered under /tmp, then its parent turned
# into a symlink to a directory outside, as an attacker would.
old_tmp_root="$work/tmp/build/result" new_tmp_root="$work/tmp/fresh/result"
spaced_root="$work/tmp/a b/result" spaced_prefix="$work/tmp/a"
old_cache_root="$HOME/.cache/nix/result" worktree_root="$HOME/.gcroots/origin/wt"
shell_root="$HOME/.cache/shell-1-link"
swapped_root="$work/tmp/swap/victim" outside_link="$work/outside/victim"
add_roots() {
  mkdir -p "$work/store/pinned"
  add_root "$old_tmp_root" '3 days ago'
  add_root "$new_tmp_root" now
  add_root "$spaced_root" '3 days ago'
  touch "$spaced_prefix"
  add_root "$old_cache_root" '3 days ago'
  add_root "$worktree_root" '3 days ago'
  add_root "$shell_root" '3 days ago'
  add_root "$swapped_root" '3 days ago'
  rm -rf "${work:?}/tmp/swap"
  mkdir -p "$work/outside"
  ln -sfn "$work/store/pinned" "$outside_link"
  touch -h -d '3 days ago' "$outside_link"
  ln -sfn "$work/outside" "$work/tmp/swap"
}
add_root() {
  mkdir -p "$(dirname "$1")" "$work/gcroots/auto"
  ln -sfn "$work/store/pinned" "$1"
  touch -h -d "$2" "$1"
  ln -sfn "$1" "$work/gcroots/auto/$(echo "$1" | sha1sum | cut -c 1-32)"
}
# Nothing outside the stale result links is touched: not a fresh root, a
# worktree's or a dev shell's, nor what a path with a space or a swapped
# parent leads to.
kept_what_must_stay() {
  [ -L "$new_tmp_root" ] || fail "a fresh GC root was removed"
  [ -L "$worktree_root" ] || fail "a worktree's GC root was removed"
  [ -L "$shell_root" ] || fail "a dev shell's GC root was removed"
  [ -e "$spaced_prefix" ] || fail "a path with a space was split into another path"
  [ -L "$outside_link" ] || fail "a symlinked parent led the delete outside"
}

# ─── The root scripts' world ─────────────────────────────────────────────────

# Two systems whose activation is recorded, the running one being old, and a
# pending deployment of the tip of main.
given_two_systems() {
  make_system old
  make_system new
  mkdir -p "$work/profiles"
  ln -sfn "$work/systems/old" "$work/current-system"
  ln -sfn "$work/systems/old" "$work/profiles/system"
  printf 'github_pat_secret' >"$work/deploy-token"
  echo '[{"id": 7, "sha": "abc123"}]' >"$GH/deployments.json"
  echo '[]' >"$GH/statuses.json"
  echo '{"sha": "abc123"}' >"$GH/main.json"
}
make_system() {
  mkdir -p "$work/systems/$1/bin"
  # shellcheck disable=SC2016 # expands in the generated script
  printf '#!/bin/sh\necho "%s $*" >>"$CALLS"\n' "$1" >"$work/systems/$1/bin/switch-to-configuration"
  chmod +x "$work/systems/$1/bin/switch-to-configuration"
}
