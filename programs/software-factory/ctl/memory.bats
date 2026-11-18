#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it
# shellcheck disable=SC2016 # a process's script expands when the process runs

load ../test_helper

# ─── mem ─────────────────────────────────────────────────────────────────────

# A process that ran $1 and then waits, ready once it has.
start_ready() {
  in_background bash -c "$1"'; touch "$0"; while :; do sleep 0.1; done' "$work/ready"
  local _
  for _ in $(seq 100); do
    [ ! -e "$work/ready" ] || return 0
    sleep 0.1
  done
  fail "the process never got ready"
}

@test "mem: lists the user's cgroups by memory, then its processes" {
  start_ready 'hog=$(head -c 50000000 /dev/zero | tr "\0" x)'
  hog=$!

  factory-ctl mem >"$work/out"

  called "systemd-cgtop -m -b -1 --depth=4 /user.slice/user-$UID.slice"
  grep -q '^Cgroups by memory:$' "$work/out" || fail_showing "$work/out" "no cgroup section"
  grep -q 'ghci.slice .* 11.5G' "$work/out" || fail_showing "$work/out" "the cgroups are missing"
  grep -q '^Processes by memory:$' "$work/out" || fail_showing "$work/out" "no process section"
  grep -Eq "^ +$hog +[0-9]+ MB  bash -c hog=" "$work/out" ||
    fail_showing "$work/out" "the biggest process is missing"
}

# ─── kill <pid> ──────────────────────────────────────────────────────────────

@test "kill: ends a process of the factory user" {
  start_session "$HOME"
  session=$!

  factory-ctl kill "$session" >"$work/out"

  ended "$session" || fail "the process survived"
  grep -qxF "Killed $session (TERM)." "$work/out" || fail_showing "$work/out" "no report"
}

@test "kill: a process that ignores TERM gets KILL" {
  start_ready 'trap "" TERM'
  stubborn=$!

  factory-ctl kill "$stubborn" >"$work/out"

  ended "$stubborn" || fail "the process survived"
  grep -qxF "Killed $stubborn (KILL, it ignored TERM)." "$work/out" || fail_showing "$work/out" "no report"
}

@test "kill: refuses a process of another user" {
  export FACTORY_KERNEL_ROOT="$work/kernel"
  mkdir -p "$FACTORY_KERNEL_ROOT/proc/4242"
  printf 'Name:\tsshd\nUid:\t0\t0\t0\t0\n' >"$FACTORY_KERNEL_ROOT/proc/4242/status"

  run -1 factory-ctl kill 4242

  grep -q "belongs to uid 0" <<<"$output" || fail "no reason given: $output"
}

@test "kill: refuses a pid that is not running" {
  run -1 factory-ctl kill 999999999

  grep -q "no process 999999999" <<<"$output" || fail "no reason given: $output"
}

@test "kill: refuses a Remote Control server unless forced" {
  clone_repo origin
  factory-ctl start origin
  start_session "$HOME"
  server=$!
  echo "$server" >"$UNITS/claude-rc@origin.service"

  run -2 factory-ctl kill "$server"
  alive "$server" || fail "the server was killed without --force"

  factory-ctl kill --force "$server"
  ended "$server" || fail "the server survived --force"
}

@test "kill: rejects anything but a pid or ghcid, before any effect" {
  for args in "" "12x" "-1" "1 2" "ghcid" "ghcid a b"; do
    # shellcheck disable=SC2086 # split into arguments on purpose
    run -1 factory-ctl kill $args
    grep -q "usage: kill" <<<"$output" || fail "no usage for 'kill $args': $output"
  done
  not_called "systemctl"
}

# ─── kill ghcid ──────────────────────────────────────────────────────────────

# A running GHCi scope of the package directory $1, named as ghcid.sh names it.
given_scope() {
  mkdir -p "$UNITS"
  touch "$UNITS/ghcid-$(systemd-escape --path "$1").scope"
}
has_scope() { [ -e "$UNITS/ghcid-$(systemd-escape --path "$1").scope" ]; }

@test "kill ghcid: stops the worktree's GHCi scopes, at its root and below" {
  checkout="$work/repos/my-repo"
  given_scope "$checkout"
  given_scope "$checkout/programs/haskell"
  given_scope "$work/repos/my-repo-old"

  factory-ctl kill ghcid "$checkout/"

  ! has_scope "$checkout" || fail "the root's scope survived"
  ! has_scope "$checkout/programs/haskell" || fail "the scope below the root survived"
  has_scope "$work/repos/my-repo-old" || fail "a sibling worktree's scope was stopped"
}

@test "kill ghcid: the main checkout leaves its Claude worktrees' scopes" {
  checkout="$work/repos/my-repo"
  worktree="$checkout/.claude/worktrees/fix-it"
  given_scope "$checkout"
  given_scope "$worktree"
  given_scope "$worktree/programs/haskell"

  factory-ctl kill ghcid "$checkout"

  ! has_scope "$checkout" || fail "the main checkout's scope survived"
  has_scope "$worktree" || fail "a Claude worktree's scope was stopped"
  has_scope "$worktree/programs/haskell" || fail "a Claude worktree's scope was stopped"
}

@test "kill ghcid: a Claude worktree stops its own scopes" {
  worktree="$work/repos/my-repo/.claude/worktrees/fix-it"
  given_scope "$worktree"
  given_scope "$worktree/programs/haskell"

  factory-ctl kill ghcid "$worktree"

  ! has_scope "$worktree" || fail "the worktree's scope survived"
  ! has_scope "$worktree/programs/haskell" || fail "the scope below the worktree survived"
}

@test "kill ghcid --all: stops ghci.slice" {
  factory-ctl kill ghcid --all

  called "systemctl --user stop ghci.slice"
}
