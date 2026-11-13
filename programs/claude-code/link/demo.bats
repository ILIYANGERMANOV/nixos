#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2312 # a stub's body expands when the stub runs, each test exports its own dirs, and a masked failure fails the assertion around it
# default.nix splices in claude_bin and activate. If a name here stops matching
# it, the assembled script fails its own shellcheck phase.

load ../../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export HOME="$WORK/home"
  mkdir -p "$HOME"
  unset CLAUDE_DEMO_DIR XDG_STATE_HOME
  # A visitor's own config dir, exported by their shell.
  export CLAUDE_CONFIG_DIR="$WORK/visitor"

  # The doubles record the dir each was handed: the activation and the flavor
  # are what write into it.
  stub claude 'echo "$CLAUDE_CONFIG_DIR $*" >"$WORK/claude-ran"'
}

demo() {
  {
    echo "claude_bin=claude"
    echo 'activate() { echo "$CLAUDE_CONFIG_DIR" >"$WORK/activated"; }'
    echo "source '$BATS_TEST_DIRNAME/demo.sh'"
  } >"$WORK/demo"
  bash -euo pipefail "$WORK/demo" "$@"
}

@test "an exported CLAUDE_CONFIG_DIR is ignored: the demo runs in its own state dir" {
  demo --resume

  [ "$(cat "$WORK/activated")" = "$HOME/.local/state/claude-demo" ]
  [ "$(cat "$WORK/claude-ran")" = "$HOME/.local/state/claude-demo --resume" ]
}

@test "the demo dir follows XDG_STATE_HOME" {
  export XDG_STATE_HOME="$WORK/state"

  demo

  [ "$(cat "$WORK/activated")" = "$WORK/state/claude-demo" ]
  [ "$(cat "$WORK/claude-ran")" = "$WORK/state/claude-demo " ]
}

@test "CLAUDE_DEMO_DIR moves the demo dir" {
  export CLAUDE_DEMO_DIR="$WORK/elsewhere" XDG_STATE_HOME="$WORK/state"

  demo

  [ "$(cat "$WORK/activated")" = "$WORK/elsewhere" ]
  [ "$(cat "$WORK/claude-ran")" = "$WORK/elsewhere " ]
}
