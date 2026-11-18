#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2119,SC2120,SC2312 # a stub's body expands when the stub runs, not every launch passes arguments, and a masked failure fails the assertion around it
# default.nix splices in these values. If a name here stops matching it, the
# assembled script fails its own shellcheck phase.

load ../../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export HOME="$WORK/home"
  mkdir -p "$HOME"

  # The relocated files, read-only as in the store.
  export store_dir="$WORK/store"
  local files="$store_dir/files"
  mkdir -p "$files/skills/engineer" "$files/agents"
  echo skill >"$files/skills/engineer/SKILL.md"
  echo role >"$files/agents/checker.md"
  echo instructions >"$files/CLAUDE.md"
  echo '{"hooks":{}}' >"$files/settings.json"
  chmod 444 "$files/skills/engineer/SKILL.md" "$files/agents/checker.md" "$files/CLAUDE.md" "$files/settings.json"

  export claude_bin=claude runtime_path="$WORK/runtime" config_dir=.claude-kategory
  export skills_dir="$files/skills" agents_dir="$files/agents"
  export instructions_file="$files/CLAUDE.md" settings_file="$files/settings.json"
  declare -gA secret_files=()

  stub claude 'echo "dir: $CLAUDE_CONFIG_DIR args: $*"'
  dir="$HOME/.claude-kategory"
}

# The whole wrapper, in the order default.nix splices its fragments.
launch() {
  {
    declare -p secret_files
    echo "source '$BATS_TEST_DIRNAME/link.sh'"
    echo "source '$BATS_TEST_DIRNAME/../load/load.sh'"
  } >"$WORK/wrapper"
  bash -euo pipefail "$WORK/wrapper" "$@"
}

# The config dir: every path, its mode and link target, and CLAUDE.md.
listing() {
  find "$dir" -printf '%p %m %l\n' | sort
  cat "$dir/CLAUDE.md"
}

@test "a fresh home gets the skills, roles and instructions in its own dir" {
  launch

  [ "$(cat "$dir/skills/engineer/SKILL.md")" = skill ]
  [ "$(cat "$dir/agents/checker.md")" = role ]
  [ "$(cat "$dir/CLAUDE.md")" = instructions ]
  [ "$(stat -c %a "$dir/CLAUDE.md")" = 600 ]
}

@test "never creates the user's own ~/.claude or ~/.claude.json" {
  launch

  [ ! -e "$HOME/.claude" ]
  [ ! -e "$HOME/.claude.json" ]
}

@test "starts claude in its dir with the harness settings before the user's arguments" {
  run launch mcp list

  [ "$status" -eq 0 ]
  [ "$output" = "dir: $dir args: --settings $settings_file mcp list" ]
}

@test "a relaunch keeps what the user owns" {
  launch
  echo '{"model":"sonnet"}' >"$dir/settings.json"
  echo '{"mcpServers":{"x":{}}}' >"$dir/.claude.json"
  mkdir "$dir/skills/synced"
  echo mine >"$dir/agents/mine.md"
  ln -s "$WORK" "$dir/skills/linked-by-hand"

  launch

  [ "$(cat "$dir/settings.json")" = '{"model":"sonnet"}' ]
  [ "$(cat "$dir/.claude.json")" = '{"mcpServers":{"x":{}}}' ]
  [ -d "$dir/skills/synced" ]
  [ "$(cat "$dir/agents/mine.md")" = mine ]
  [ -L "$dir/skills/linked-by-hand" ]
}

@test "a relaunch restores the instructions edited by hand" {
  launch
  echo "by hand" >"$dir/CLAUDE.md"

  launch

  [ "$(cat "$dir/CLAUDE.md")" = instructions ]
}

@test "a skill gone from the store is unlinked" {
  mkdir -p "$dir/skills"
  ln -s "$store_dir/old-files/skills/retired" "$dir/skills/retired"

  launch

  [ ! -L "$dir/skills/retired" ]
  [ -L "$dir/skills/engineer" ]
}

@test "a second launch changes nothing" {
  launch
  local first
  first=$(listing)

  launch

  [ "$(listing)" = "$first" ]
}
