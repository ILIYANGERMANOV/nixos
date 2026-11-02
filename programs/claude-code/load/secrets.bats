#!/usr/bin/env bats
# shellcheck disable=SC2016 # a probe's body expands when the probe runs
# lib.nix splices in mcp_secrets. If its name here stops matching, the assembled
# script fails its own shellcheck phase.

load ../../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  mcp_secrets=()
  stub hostname 'echo testhost'
}

# Runs secrets.sh with this test's mcp_secrets, then $1 in the same shell: an
# array cannot cross the environment, and an export only reaches what follows.
read_secrets() {
  {
    declare -p mcp_secrets
    echo "source '$BATS_TEST_DIRNAME/secrets.sh'"
    echo "$1"
  } >"$WORK/script"
  bash -euo pipefail "$WORK/script"
}

@test "a declared secret is exported by value" {
  echo s3cret >"$WORK/token"
  mcp_secrets=(coda CODA_TOKEN "$WORK/token")

  run read_secrets 'echo "$CODA_TOKEN"'

  [ "$output" = s3cret ]
}

@test "every declared secret is exported under its own name" {
  echo one >"$WORK/a"
  echo two >"$WORK/b"
  mcp_secrets=(coda CODA_TOKEN "$WORK/a" figma FIGMA_KEY "$WORK/b")

  run read_secrets 'echo "$CODA_TOKEN $FIGMA_KEY"'

  [ "$output" = "one two" ]
}

@test "a missing secret is fatal and names the server and path" {
  echo one >"$WORK/a"
  mcp_secrets=(figma FIGMA_KEY "$WORK/a" coda CODA_TOKEN "$WORK/absent")

  run --separate-stderr read_secrets 'echo reached'

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"MCP server 'coda' needs $WORK/absent"* ]]
}
