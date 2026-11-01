# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Rewrites what this flavor owns, loads its secrets and execs Claude Code.

# Validate one secret file exists, then export it as an env var.
# Secrets are NOT written to any file. Claude Code's expandVars (confirmed enabled
# for user scope in source) resolves ${VAR} references in ~/.claude.json from the
# process environment inherited via exec.
#
# A missing file is fatal, not a reason to drop the server: this server is only
# here because the host DECLARED its secret, so a missing file means the
# promise is broken (no age key, or a rebuild that never ran) rather than that
# the feature is off. Hosts that genuinely lack the secret never get this far.
#
# Servers that name no secrets contribute nothing, so the empty case needs no
# guard of its own.
read_secret() {
  local server=$1 var=$2 path=$3 value
  if [ ! -f "$path" ]; then
    echo "Error: MCP server '$server' needs $path, which does not exist." >&2
    # shellcheck disable=SC2312 # A failed hostname costs one word of a fatal message.
    echo "$(hostname -s) declares this secret via myConfig.secrets, so it should be there." >&2
    echo "Check the age key (just darwin-install-age-key) and re-run darwin-rebuild switch." >&2
    exit 1
  fi
  value=$(cat "$path")
  export "$var=$value"
}

mkdir -p "$HOME/.claude"
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
install -m 600 "$instructions_file" "$HOME/.claude/CLAUDE.md"
install -m 600 "$settings_file" "$HOME/.claude/settings.json"

# mcp_secrets is flat: server, variable, path, then the next server.
for ((i = 0; i < ${#mcp_secrets[@]}; i += 3)); do
  read_secret "${mcp_secrets[i]}" "${mcp_secrets[i + 1]}" "${mcp_secrets[i + 2]}"
done

# Atomically update ~/.claude.json with this flavor's MCP servers.
# mcp_static_file is a Nix store path with the static JSON (env var references only).
# Replaces mcpServers entirely so switching flavors is always clean.
[ -f "$HOME/.claude.json" ] || echo '{}' >"$HOME/.claude.json"
_claude_tmp=$(mktemp "$HOME/.claude.json.XXXXXX")
trap 'rm -f "$_claude_tmp"' EXIT
jq --slurpfile mcp "$mcp_static_file" ".mcpServers = \$mcp[0]" \
  "$HOME/.claude.json" >"$_claude_tmp"
mv "$_claude_tmp" "$HOME/.claude.json"

export PATH="$runtime_path:$PATH"
for var in "${!secret_files[@]}"; do
  export "$var=${secret_files[$var]}"
done
exec "$claude_bin" "$@"
