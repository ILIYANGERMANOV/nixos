#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2312 # a stub's body expands when the stub runs, each test exports in its own subshell, and a masked failure fails the assertion around it
# default.nix splices in these values. If a name here stops matching it, the
# assembled script fails its own shellcheck phase.

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export HOME="$WORK/home"
  mkdir -p "$HOME"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

  # What OpenCode is started with: its arguments, then its environment.
  stub opencode 'printf "arg: %s\n" "$@"
for var in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; do echo "$var=${!var}"; done
echo "user: $OPENCODE_KATEGORY_USER_XDG"'
}

launch() {
  {
    echo 'kategory_dir=.opencode-kategory'
    echo 'declare -A moved_xdg=([XDG_CACHE_HOME]=cache [XDG_CONFIG_HOME]=config [XDG_DATA_HOME]=data [XDG_STATE_HOME]=state)'
    echo 'declare -A user_xdg_defaults=([XDG_CACHE_HOME]=.cache [XDG_CONFIG_HOME]=.config [XDG_DATA_HOME]=.local/share)'
    echo 'user_xdg_var=OPENCODE_KATEGORY_USER_XDG'
    echo "source '$BATS_TEST_DIRNAME/launch.sh'"
  } >"$WORK/wrapper"
  bash -euo pipefail "$WORK/wrapper" "$@"
}

# The saved user dirs, one `name=dir` per line, sorted.
saved() {
  sed -n 's/^user: //p' <<<"$1" | jq -r 'to_entries[] | "\(.key)=\(.value)"' | sort
}

@test "OpenCode gets all four dirs under its own dir, whatever the user set" {
  export XDG_CONFIG_HOME="$WORK/mine" XDG_STATE_HOME="$WORK/my-state"

  run launch

  [ "$status" -eq 0 ]
  [[ "$output" == *"XDG_CONFIG_HOME=$HOME/.opencode-kategory/config"* ]]
  [[ "$output" == *"XDG_DATA_HOME=$HOME/.opencode-kategory/data"* ]]
  [[ "$output" == *"XDG_STATE_HOME=$HOME/.opencode-kategory/state"* ]]
  [[ "$output" == *"XDG_CACHE_HOME=$HOME/.opencode-kategory/cache"* ]]
}

@test "unset user dirs are saved as their spec defaults" {
  run launch

  [ "$status" -eq 0 ]
  [ "$(saved "$output")" = "XDG_CACHE_HOME=$HOME/.cache
XDG_CONFIG_HOME=$HOME/.config
XDG_DATA_HOME=$HOME/.local/share" ]
}

@test "user dirs that are set are saved as set, an empty one as its default, and never the state dir" {
  export XDG_CONFIG_HOME="$WORK/my config" XDG_DATA_HOME="" XDG_CACHE_HOME="$WORK/my-cache"
  export XDG_STATE_HOME="$WORK/my-state"

  run launch

  [ "$status" -eq 0 ]
  [ "$(saved "$output")" = "XDG_CACHE_HOME=$WORK/my-cache
XDG_CONFIG_HOME=$WORK/my config
XDG_DATA_HOME=$HOME/.local/share" ]
}

@test "the arguments reach OpenCode as given" {
  run launch run --command engineer "fix the bug"

  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^arg: //p' <<<"$output")" = 'run
--command
engineer
fix the bug' ]
}

@test "nothing is written in HOME" {
  run launch

  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$HOME")" ]
}
