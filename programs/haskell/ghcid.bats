#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2312 # a stub's body expands when the stub runs, and a masked failure fails the assertion around it
# The session client's verdicts, against hand-written session files, and the
# daemon's launch and reaping with stubs: the daemon itself needs GHC, so
# `nix run .#kernel-quick-typecheck` covers it.

load ../shell-check/test_helper.bash

setup() {
  # shellcheck source=programs/haskell/ghcid.sh
  source "$BATS_TEST_DIRNAME/ghcid.sh"
  name=kernel
  source_dirs=(src)
  cabal_files=(state.cabal)
  cd "$BATS_TEST_TMPDIR" || exit
  mkdir -p src state
  touch state.cabal src/A.hs
  session_paths "$BATS_TEST_TMPDIR/state"
  touch -d '-1 minute' state.cabal src/A.hs
  touch -d '-30 seconds' "$session"
}

@test "a green verdict is one line without its time" {
  echo 'All good (3 modules, at 12:00:01)' >"$outf"
  run report
  [ "$status" -eq 0 ]
  [ "$output" = 'All good (3 modules)' ]
}

@test "a red verdict is GHC's output, capped" {
  max_report_lines=2
  printf 'src/A.hs:1:1: error\nline\nline\nline\n' >"$outf"
  run report
  [ "$status" -eq 1 ]
  [ "${lines[2]}" = "[... 2 more lines, see $outf]" ]
}

@test "a verdict older than a source edit is stale" {
  echo 'All good' >"$outf"
  [ -z "$(stale_inputs)" ]
  touch src/A.hs
  [ "$(stale_inputs)" = src/A.hs ]
}

@test "a cabal edit after the session started is stale" {
  echo 'All good' >"$outf"
  touch state.cabal
  [ "$(stale_inputs)" = state.cabal ]
}

@test "a filter that runs no example fails" {
  request_id=7
  echo '7 0 0' >"$test_result"
  run report_run Nothing
  [ "$status" -eq 1 ]
  [ "$output" = 'kernel: no test matches "Nothing"' ]
}

@test "a lock whose owner died is taken over" {
  mkdir "$lock"
  echo 999999999 >"$lock/owner"
  acquire_lock
  [ "$(<"$lock/owner")" = "$$" ]
}

# A daemon launch with nix and the watchdog stubbed to record their arguments.
launch_daemon() {
  root=$BATS_TEST_TMPDIR
  stub nix 'printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/nix.args"'
  stub kernel-ghcid-watchdog :
  stub systemd-escape 'echo "escaped$2" | tr / -'
  stub systemd-run 'printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/systemd-run.args"
while [ "$1" != nix ]; do shift; done
exec "$@"'
  start_daemon
  wait_for "$BATS_TEST_TMPDIR/nix.args"
}

@test "on the factory the daemon runs in a capped scope under ghci.slice" {
  stub systemctl '[ "$*" = "--user show -p LoadState --value ghci.slice" ] && echo loaded'
  launch_daemon
  [[ "$(<"$BATS_TEST_TMPDIR/systemd-run.args")" == "--user --scope --collect --quiet --unit=ghcid-escaped${PWD//\//-} --slice=ghci.slice -p MemoryMax=16G -p MemorySwapMax=0 nix develop $root#kernel "* ]]
}

@test "without ghci.slice the daemon starts as a plain process" {
  stub systemctl 'echo not-found'
  launch_daemon
  [ ! -e "$BATS_TEST_TMPDIR/systemd-run.args" ]
  [[ "$(<"$BATS_TEST_TMPDIR/nix.args")" == "develop $root#kernel "* ]]
}

@test "the watchdog stops the daemon once its worktree is removed" {
  local daemon
  bash -c 'sleep 1000; :' "ghcid --outputfile $outf" >/dev/null 2>&1 3>&- &
  daemon=$!
  touch "$lastuse"
  # One watchdog tick, then its loop ends: one that missed the removal returns
  # with the daemon alive.
  stub sleep '[ "$1" != 60 ] || [ ! -e "$BATS_TEST_TMPDIR/slept" ] || exit 1
touch "$BATS_TEST_TMPDIR/slept"'
  run_ghcid_watchdog "$state" "$BATS_TEST_TMPDIR/removed"
  # Killed, it is a zombie until the test's shell reaps it.
  [ ! -e "/proc/$daemon" ] || [ "$(cut -d ' ' -f 3 "/proc/$daemon/stat")" = Z ]
}
