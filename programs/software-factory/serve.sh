# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Applies the flavor, trusts the directory and replaces this process
# with a Remote Control server for it.
serve() {
  local dir="$1" name="$2"
  shift 2

  open_factory_lock
  flock 9
  "$claude_bin" --version >/dev/null
  trust "$dir"
  exec 9>&-

  GH_TOKEN=$(cat "$gh_token_file")
  export GH_TOKEN
  cd "$dir"
  exec "$claude_unwrapped" remote-control --name "$name" "$@"
}

# Remote Control refuses an untrusted directory when nobody is at a
# terminal to confirm it, and on its first run it waits on stdin for
# "Enable Remote Control? (y/n)" - forever, under systemd, while the
# unit reports active. These are the records the two answers write.
trust() {
  local config="$HOME/.claude.json" tmp
  [ -f "$config" ] || echo '{}' >"$config"
  tmp=$(mktemp "$config.XXXXXX")
  jq --arg dir "$1" '.projects[$dir].hasTrustDialogAccepted = true | .remoteDialogSeen = true' "$config" >"$tmp"
  mv "$tmp" "$config"
}
