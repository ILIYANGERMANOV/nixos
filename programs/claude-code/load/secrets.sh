# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Exports this flavor's MCP secrets. It runs before link.sh, so a missing secret
# stops the launch before anything in ~/.claude or ~/.claude.json changes.

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

# mcp_secrets is flat: server, variable, path, then the next server.
for ((i = 0; i < ${#mcp_secrets[@]}; i += 3)); do
  read_secret "${mcp_secrets[i]}" "${mcp_secrets[i + 1]}" "${mcp_secrets[i + 2]}"
done
