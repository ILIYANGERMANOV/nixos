# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# claude-demo: the `claude` flavor in its own config dir, so a visitor's
# ~/.claude and ~/.claude.json stay untouched. The dir holds their login too.
# The roles go in first (activate): no Home Manager installs them there.
#
# CLAUDE_DEMO_DIR, never an inherited CLAUDE_CONFIG_DIR, moves the dir: the
# flavor relinks skills there, which would wipe a real config's skills.
export CLAUDE_CONFIG_DIR="${CLAUDE_DEMO_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-demo}"
activate
exec "$claude_bin" "$@"
