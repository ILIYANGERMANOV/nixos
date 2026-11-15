#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs
# The cabal runners, with cabal and the linters stubbed to log their arguments.

load ../shell-check/test_helper.bash

setup() {
  # shellcheck source=programs/haskell/cabal.sh
  source "$BATS_TEST_DIRNAME/cabal.sh"
  cabal_file=state.cabal
  source_dirs=(src test)
  test_flags=(--seed=351)
  declare -gA bins=([STATE_BIN]=state)
  log=$BATS_TEST_TMPDIR/log
  export log
  for tool in cabal hlint fourmolu cabal-fmt; do
    stub "$tool" "echo \"$tool \$*\" >>\"\$log\"; [ \"\$1\" = list-bin ] && last=\${!#} && echo /built/\${last#exe:}; exit 0"
  done
}

@test "a filtered test matches one pattern however many words, and fails on none" {
  run_test State Table
  grep -qx -- 'cabal test -v1 --test-show-details=direct --test-option=--no-color --test-option=--format=failed-examples --test-option=--seed=351 --test-option=--match --test-option=State Table --test-option=--fail-on=empty' "$log"
}

@test "a test sees each bin variable as the executable's built path" {
  stub cabal 'last=${!#}; [ "$1" = list-bin ] && echo "/built/${last#exe:}"; [ "$1" != test ] || echo "$STATE_BIN" >>"$log"; exit 0'
  run_test
  grep -qx /built/state "$log"
}

@test "lint runs every linter and fails when one fails" {
  stub hlint 'echo "hlint $*" >>"$log"; exit 1'
  run run_lint
  [ "$status" -eq 1 ]
  grep -q '^fourmolu -q --mode check src test$' "$log"
  grep -q '^cabal-fmt --check state.cabal$' "$log"
}
