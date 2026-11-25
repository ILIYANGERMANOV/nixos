# shellcheck shell=bash disable=SC2154 # set by default.nix: the assembled script is checked whole
# opencode-kategory's effect: OpenCode gets its own data, state and cache dirs
# under ~/$kategory_dir and its config dir in the read-only $config_home, so it
# reads and writes nothing of the user's own ~/.config/opencode. The user's
# dirs ride along in $user_xdg_var as one JSON object, for plugin/kategory.js
# to hand back to every shell OpenCode runs.
#
# Untouched: ~/$kategory_dir and the user's dirs. OpenCode and `state` create
# what they need under the moved dirs; nothing here writes a file.
#
# An unset or empty dir is saved as its spec default, the dir gh and git use
# then. On macOS a tool that reads ~/Library unless XDG_CONFIG_HOME is set would
# move to ~/.config in OpenCode's shells; gh and git read ~/.config either way.

user_xdg=()
for var in "${!user_xdg_defaults[@]}"; do
  user_xdg+=(--arg "$var" "${!var:-$HOME/${user_xdg_defaults[$var]}}")
done
saved=$(jq -cn '$ARGS.named' "${user_xdg[@]}")
export "$user_xdg_var=$saved"

for var in "${!moved_xdg[@]}"; do
  export "$var=$HOME/$kategory_dir/${moved_xdg[$var]}"
done
export XDG_CONFIG_HOME=$config_home

exec opencode "$@"
