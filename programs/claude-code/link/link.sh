# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Rewrites what this flavor owns in ~/.claude and ~/.claude.json.

# Claude Code reads both from CLAUDE_CONFIG_DIR when it is set, .claude.json
# included, so a launcher can keep a separate config dir (claude-demo does).
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
claude_json="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

mkdir -p "$claude_dir"
apply_skills

# Rewrite ~/.claude/CLAUDE.md from the store on every launch.
#
# User-scope memory is Nix-owned, on the same terms as ~/.claude/skills: the
# file is replaced wholesale, so anything written into it by hand or by the `#`
# memory shortcut is discarded on the next launch. Machine-local rules belong
# in a project's own CLAUDE.md, which still stacks on top of this one.
#
# `install -m 600`, not `cp`: store paths are mode 444 and Claude Code never
# rewrites CLAUDE.md, so a plain `cp` would succeed once and then fail with
# EACCES on every later launch - fatal under `set -o errexit`.
install -m 600 "$instructions_file" "$claude_dir/CLAUDE.md"
install -m 600 "$settings_file" "$claude_dir/settings.json"

# Atomically update ~/.claude.json with this flavor's MCP servers.
# mcp_static_file is a Nix store path with the static JSON (env var references only).
# Replaces mcpServers entirely so switching flavors is always clean.
[ -f "$claude_json" ] || echo '{}' >"$claude_json"
_claude_tmp=$(mktemp "$claude_json.XXXXXX")
trap 'rm -f "$_claude_tmp"' EXIT
jq --slurpfile mcp "$mcp_static_file" ".mcpServers = \$mcp[0]" \
  "$claude_json" >"$_claude_tmp"
mv "$_claude_tmp" "$claude_json"
