#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2119,SC2120,SC2312 # a stub's body expands when the stub runs, not every test passes arguments, and a masked failure fails the assertion around it
# lib.nix splices in these values and apply_skills. If a name here stops matching
# it, the assembled script fails its own shellcheck phase.

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export HOME="$WORK/home"
  mkdir -p "$HOME"

  # Read-only, as in the store.
  echo instructions >"$WORK/instructions"
  echo '{"model":"opus"}' >"$WORK/settings"
  echo '{"coda":{"url":"https://example.com"}}' >"$WORK/mcp.json"
  chmod 444 "$WORK/instructions" "$WORK/settings" "$WORK/mcp.json"

  export instructions_file="$WORK/instructions" settings_file="$WORK/settings"
  export mcp_static_file="$WORK/mcp.json" claude_bin="$WORK/bin/claude"
  export runtime_path="$WORK/runtime"
  mcp_secrets=()
  declare -gA secret_files=()

  stub claude 'echo "args: $*"'
  stub hostname 'echo testhost'
}

# A flavor's script: its arrays cannot cross the environment.
launch() {
  {
    declare -p mcp_secrets secret_files
    echo 'apply_skills() { touch "$WORK/skills-applied"; }'
    echo "source '$BATS_TEST_DIRNAME/wrapper.sh'"
  } >"$WORK/flavor"
  bash -euo pipefail "$WORK/flavor" "$@"
}

@test "execs claude with its arguments and exit code" {
  stub claude 'echo "args: $*"; exit 9'

  run launch --resume "two words"

  [ "$status" -eq 9 ]
  [ "$output" = "args: --resume two words" ]
}

@test "applies the skills before claude starts" {
  stub claude '[ -e "$WORK/skills-applied" ] && echo applied'

  run launch

  [ "$output" = applied ]
}

@test "puts the flavor's runtime first on PATH" {
  mkdir "$WORK/runtime"
  stub tool 'echo the-callers'
  printf '#!%s\necho the-flavors\n' "$BASH" >"$WORK/runtime/tool"
  chmod +x "$WORK/runtime/tool"
  stub claude 'tool'

  run launch

  [ "$output" = the-flavors ]
}

@test "a declared MCP secret reaches claude by value" {
  echo s3cret >"$WORK/token"
  mcp_secrets=(coda CODA_TOKEN "$WORK/token")
  stub claude 'echo "$CODA_TOKEN"'

  run launch

  [ "$output" = s3cret ]
}

@test "a missing MCP secret is fatal and names the server and path" {
  mcp_secrets=(coda CODA_TOKEN "$WORK/absent")

  run --separate-stderr launch

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"MCP server 'coda' needs $WORK/absent"* ]]
}

@test "a secret file reaches claude as its path, never its value" {
  echo s3cret >"$WORK/token"
  secret_files=([GH_TOKEN_FILE]="$WORK/token")
  stub claude 'echo "$GH_TOKEN_FILE"'

  run launch

  [ "$output" = "$WORK/token" ]
}

@test "the instructions and settings replace what the last launch left" {
  mkdir "$HOME/.claude"
  echo "by hand" >"$HOME/.claude/CLAUDE.md"
  launch

  launch

  [ "$(cat "$HOME/.claude/CLAUDE.md")" = instructions ]
  [ "$(cat "$HOME/.claude/settings.json")" = '{"model":"opus"}' ]
}

@test "a second launch rewrites files that came from the read-only store" {
  launch

  run launch

  [ "$status" -eq 0 ]
}

@test "the MCP servers are replaced and the rest of ~/.claude.json stays" {
  echo '{"projects":{"a":1},"mcpServers":{"old":{}}}' >"$HOME/.claude.json"

  launch

  [ "$(jq -cS . "$HOME/.claude.json")" = '{"mcpServers":{"coda":{"url":"https://example.com"}},"projects":{"a":1}}' ]
}

@test "a first launch creates ~/.claude.json" {
  launch

  [ "$(jq -c . "$HOME/.claude.json")" = '{"mcpServers":{"coda":{"url":"https://example.com"}}}' ]
}

@test "an unreadable ~/.claude.json stops the launch, untouched and with no temp file" {
  echo 'not json' >"$HOME/.claude.json"

  run --separate-stderr launch

  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(cat "$HOME/.claude.json")" = "not json" ]
  [ "$(find "$HOME" -maxdepth 1 -name '.claude.json.*' | wc -l)" -eq 0 ]
}
