#!/usr/bin/env bats
# shellcheck disable=SC2312 # a masked failure fails the assertion around it

load ../../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  mkdir -p "$WORK/farm/alpha" "$WORK/farm/beta"
}

apply_skills() {
  bash -euo pipefail "$BATS_TEST_DIRNAME/apply-skills.sh" "$@"
}

@test "links each skill of the farm" {
  apply_skills "$WORK/config" "$WORK/farm"

  [ "$(readlink "$WORK/config/skills/alpha")" = "$WORK/farm/alpha" ]
  [ "$(readlink "$WORK/config/skills/beta")" = "$WORK/farm/beta" ]
}

@test "a skill placed by hand is discarded" {
  mkdir -p "$WORK/config/skills/by-hand"

  apply_skills "$WORK/config" "$WORK/farm"

  [ ! -e "$WORK/config/skills/by-hand" ]
}

@test "without a farm, no skills dir is left" {
  mkdir -p "$WORK/config/skills/alpha"

  apply_skills "$WORK/config"

  [ ! -e "$WORK/config/skills" ]
}
