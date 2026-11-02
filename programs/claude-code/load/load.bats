#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2119,SC2120 # a stub's body expands when the stub runs, and not every test passes arguments
# lib.nix splices in these values. If a name here stops matching it, the
# assembled script fails its own shellcheck phase.

load ../../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export claude_bin=claude runtime_path="$WORK/runtime"
  mcp_secrets=()
  declare -gA secret_files=()

  stub claude 'echo "args: $*"'
  stub hostname 'echo testhost'
}

# A flavor's script: its arrays cannot cross the environment. $1... are the
# fragments it sources, in order.
flavor() {
  {
    declare -p mcp_secrets secret_files
    echo 'apply_skills() { :; }'
    local fragment
    for fragment in "$@"; do
      echo "source '$BATS_TEST_DIRNAME/$fragment'"
    done
  } >"$WORK/flavor"
}

load_claude() {
  flavor secrets.sh load.sh
  bash -euo pipefail "$WORK/flavor" "$@"
}

# The whole wrapper, its fragments in the order link/lib.nix splices them.
launch() {
  flavor secrets.sh ../link/link.sh load.sh
  bash -euo pipefail "$WORK/flavor" "$@"
}

@test "execs claude with its arguments and exit code" {
  stub claude 'echo "args: $*"; exit 9'

  run load_claude --resume "two words"

  [ "$status" -eq 9 ]
  [ "$output" = "args: --resume two words" ]
}

@test "puts the flavor's runtime first on PATH" {
  mkdir "$WORK/runtime"
  stub tool 'echo the-flavors'
  mv "$WORK/bin/tool" "$WORK/runtime/tool"
  stub tool 'echo the-callers'
  stub claude 'tool'

  run load_claude

  [ "$output" = the-flavors ]
}

@test "a declared MCP secret reaches claude by value" {
  echo s3cret >"$WORK/token"
  mcp_secrets=(coda CODA_TOKEN "$WORK/token")
  stub claude 'echo "$CODA_TOKEN"'

  run load_claude

  [ "$output" = s3cret ]
}

@test "a missing MCP secret is fatal and names the server and path" {
  mcp_secrets=(coda CODA_TOKEN "$WORK/absent")

  run --separate-stderr load_claude

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"MCP server 'coda' needs $WORK/absent"* ]]
}

@test "a secret file reaches claude as its path, never its value" {
  echo s3cret >"$WORK/token"
  secret_files=([GH_TOKEN_FILE]="$WORK/token")
  stub claude 'echo "$GH_TOKEN_FILE"'

  run load_claude

  [ "$output" = "$WORK/token" ]
}

@test "a missing MCP secret stops the launch before ~/.claude.json changes" {
  export HOME="$WORK/home" instructions_file="$WORK/instructions"
  export settings_file="$WORK/settings" mcp_static_file="$WORK/mcp.json"
  mkdir "$HOME"
  echo instructions >"$instructions_file"
  echo '{}' >"$settings_file"
  echo '{"coda":{}}' >"$mcp_static_file"
  echo '{"mcpServers":{"old":{}}}' >"$HOME/.claude.json"
  mcp_secrets=(coda CODA_TOKEN "$WORK/absent")

  run --separate-stderr launch

  [ "$status" -eq 1 ]
  [ "$(<"$HOME/.claude.json")" = '{"mcpServers":{"old":{}}}' ]
}
