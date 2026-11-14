# shellcheck shell=bash
# The cabal runners of a Haskell package (programs/haskell), run in its
# directory with its toolchain on PATH. Nix sets before it: cabal_file,
# source_dirs, components, test_flags and bins, the suite's variables naming a
# built executable.

# Every component, the test suite too: cabal.project enables tests.
run_build() {
  cabal build -v1 all
}

# The suite, or with arguments the examples `--match` selects, which must be
# at least one. Builds first: a spec may run an executable.
run_test() {
  local -a options=(--no-color --format=failed-examples "${test_flags[@]}")
  if [ "$#" -gt 0 ]; then
    options+=(--match "$*" --fail-on=empty)
  fi
  run_build
  export_bins
  cabal test -v1 --test-show-details=direct "${options[@]/#/--test-option=}"
}

# Every linter, each reporting, so one run shows every miss.
run_lint() {
  local status=0
  hlint "${source_dirs[@]}" || status=1
  fourmolu -q --mode check "${source_dirs[@]}" || status=1
  cabal-fmt --check "$cabal_file" || status=1
  return "$status"
}

run_format() {
  fourmolu -q --mode inplace "${source_dirs[@]}"
  cabal-fmt --inplace "$cabal_file"
}

# The quick runners' GHCi session, every component in one multi-unit repl.
# $1 is touched first, before cabal reads the cabal files: ghcid.sh's stamp.
run_repl() {
  touch "$1"
  export_bins
  exec cabal repl -v1 --enable-multi-repl "${components[@]}"
}

# Paths only: a session's executables are the last build's.
export_bins() {
  local var path
  for var in "${!bins[@]}"; do
    path=$(cabal list-bin -v0 "exe:${bins[$var]}")
    export "$var=$path"
  done
}
