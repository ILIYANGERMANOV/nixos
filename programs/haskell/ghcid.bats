#!/usr/bin/env bats
# The session client's verdicts, against hand-written session files: the
# daemon itself needs GHC, so `nix run .#kernel-quick-typecheck` covers it.

load ../shell-check/test_helper.bash

setup() {
  # shellcheck source=programs/haskell/ghcid.sh
  source "$BATS_TEST_DIRNAME/ghcid.sh"
  name=kernel
  source_dirs=(src)
  cabal_files=(state.cabal)
  cd "$BATS_TEST_TMPDIR"
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
