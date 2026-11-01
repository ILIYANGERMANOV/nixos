# shellcheck shell=bash
# What the script suites share. They run the `.sh` beside them, so a value Nix
# would splice in is a variable the suite sets, and what the script calls is a stub.

bats_require_minimum_version 1.5.0

# A program named $1 on PATH, with $2 as its body. It finds bash through the
# suite's own: the build sandbox has no /usr/bin/env.
stub() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!%s\n%s\n' "$BASH" "$2" >"$bin/$1"
  chmod +x "$bin/$1"
  PATH="$bin:$PATH"
}

# Whether $1 appears within ten seconds. Exported: a stub can wait on the test.
wait_for() {
  local tries
  for ((tries = 0; tries < 1000; tries++)); do
    [ ! -e "$1" ] || return 0
    sleep 0.01
  done
  echo "never appeared: $1" >&2
  return 1
}
export -f wait_for
