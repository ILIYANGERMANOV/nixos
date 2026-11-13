#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2312 # a stub's body expands when the stub runs, each test exports its own CLAUDE_CONFIG_DIR, and a masked failure fails the assertion around it
# lib.nix splices in these values and apply_skills. If a name here stops matching
# it, the assembled script fails its own shellcheck phase.

load ../../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export HOME="$WORK/home"
  mkdir -p "$HOME"
  unset CLAUDE_CONFIG_DIR

  # Read-only, as in the store.
  echo instructions >"$WORK/instructions"
  echo '{"model":"opus"}' >"$WORK/settings"
  echo '{"coda":{"url":"https://example.com"}}' >"$WORK/mcp.json"
  chmod 444 "$WORK/instructions" "$WORK/settings" "$WORK/mcp.json"

  export instructions_file="$WORK/instructions" settings_file="$WORK/settings"
  export mcp_static_file="$WORK/mcp.json"
}

link() {
  link_with 'apply_skills() { touch "$WORK/skills-applied"; }'
}

# The flavor with $1 as its apply_skills.
link_with() {
  {
    echo "$1"
    echo "source '$BATS_TEST_DIRNAME/link.sh'"
  } >"$WORK/flavor"
  bash -euo pipefail "$WORK/flavor"
}

@test "applies the skills" {
  link

  [ -e "$WORK/skills-applied" ]
}

@test "the instructions and settings replace what is there" {
  mkdir "$HOME/.claude"
  echo "by hand" >"$HOME/.claude/CLAUDE.md"
  echo "by hand" >"$HOME/.claude/settings.json"

  link

  [ "$(cat "$HOME/.claude/CLAUDE.md")" = instructions ]
  [ "$(cat "$HOME/.claude/settings.json")" = '{"model":"opus"}' ]
}

@test "the instructions and settings are private to the user" {
  link

  [ "$(stat -c %a "$HOME/.claude/CLAUDE.md")" = 600 ]
  [ "$(stat -c %a "$HOME/.claude/settings.json")" = 600 ]
}

@test "with CLAUDE_CONFIG_DIR set, the link writes there and not in HOME" {
  export CLAUDE_CONFIG_DIR="$WORK/demo"

  link

  [ "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")" = instructions ]
  [ "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" = '{"model":"opus"}' ]
  [ "$(jq -c . "$CLAUDE_CONFIG_DIR/.claude.json")" = '{"mcpServers":{"coda":{"url":"https://example.com"}}}' ]
  [ ! -e "$HOME/.claude" ]
  [ ! -e "$HOME/.claude.json" ]
}

@test "with CLAUDE_CONFIG_DIR set, the real apply_skills links the skills there" {
  export CLAUDE_CONFIG_DIR="$WORK/demo"
  mkdir -p "$WORK/farm/alpha" "$HOME/.claude/skills/mine"

  # As lib.nix's mkApplySkills renders it.
  link_with "apply_skills() { bash '$BATS_TEST_DIRNAME/apply-skills.sh' \"\$claude_dir\" '$WORK/farm'; }"

  [ "$(readlink "$CLAUDE_CONFIG_DIR/skills/alpha")" = "$WORK/farm/alpha" ]
  [ -d "$HOME/.claude/skills/mine" ]
}

@test "a second link rewrites files that came from the read-only store" {
  link

  run link

  [ "$status" -eq 0 ]
}

@test "the MCP servers are replaced and the rest of ~/.claude.json stays" {
  echo '{"projects":{"a":1},"mcpServers":{"old":{}}}' >"$HOME/.claude.json"

  link

  [ "$(jq -cS . "$HOME/.claude.json")" = '{"mcpServers":{"coda":{"url":"https://example.com"}},"projects":{"a":1}}' ]
}

@test "a first link creates ~/.claude.json" {
  link

  [ "$(jq -c . "$HOME/.claude.json")" = '{"mcpServers":{"coda":{"url":"https://example.com"}}}' ]
}

@test "an unreadable ~/.claude.json stops the link, untouched and with no temp file" {
  echo 'not json' >"$HOME/.claude.json"

  run --separate-stderr link

  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.claude.json")" = "not json" ]
  [ "$(find "$HOME" -maxdepth 1 -name '.claude.json.*' | wc -l)" -eq 0 ]
}
