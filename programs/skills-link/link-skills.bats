#!/usr/bin/env bats
# shellcheck disable=SC2312 # a masked failure fails the assertion around it
# The relink under races and dangling links is the factory's skills.bats; this
# suite pins where it writes.

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export HOME="$WORK/home"
  mkdir -p "$HOME" "$WORK/farm/alpha"
  unset CLAUDE_CONFIG_DIR
}

link_skills() {
  bash -euo pipefail "$BATS_TEST_DIRNAME/link-skills.sh" "$WORK/farm"
}

@test "links the farm's skills into ~/.claude/skills" {
  link_skills

  [ "$(readlink "$HOME/.claude/skills/alpha")" = "$WORK/farm/alpha" ]
}

@test "with CLAUDE_CONFIG_DIR set, links the skills there and not in HOME" {
  export CLAUDE_CONFIG_DIR="$WORK/demo"

  link_skills

  [ "$(readlink "$CLAUDE_CONFIG_DIR/skills/alpha")" = "$WORK/farm/alpha" ]
  [ ! -e "$HOME/.claude" ]
}
