# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Points Claude Code at ~/<config_dir> and writes what Nix owns there: the
# skill and role links and CLAUDE.md. Everything else in it is the user's:
# settings.json, .claude.json with its MCP servers, the login, plugins and
# projects are never written. The harness settings go in as `--settings`, a
# layer above the user's settings.json that Claude Code merges hooks and
# permission lists across, so the user's own file stays theirs.

export CLAUDE_CONFIG_DIR="$HOME/$config_dir"
mkdir -p "$CLAUDE_CONFIG_DIR"

# sync_links <farm> <dir>: one link in <dir> per entry of <farm>, updated in
# place. Each link is renamed over its old self, so a running session never
# misses an entry, and stale links go last. Only links into the store are
# Nix's: Claude Code's own skills/synced directory and anything the user adds
# stay. The scheme of programs/skills-link, which is written for ~/.claude
# and is part of every factory's build.
sync_links() {
  local farm=$1 live=$2 scratch link entry
  mkdir -p "$live"
  scratch=$(mktemp -d "$CLAUDE_CONFIG_DIR/.links.XXXXXX")
  ln -s "$farm"/* "$scratch/"
  for link in "$scratch"/*; do
    mv --no-target-directory "$link" "$live/${link##*/}"
  done
  rmdir "$scratch"
  for entry in "$live"/*; do
    if [ -L "$entry" ] && [ ! -e "$farm/${entry##*/}" ]; then
      case $(readlink "$entry") in
        "$store_dir"/*) rm -f "$entry" ;;
        *) ;;
      esac
    fi
  done
}

sync_links "$skills_dir" "$CLAUDE_CONFIG_DIR/skills"
sync_links "$agents_dir" "$CLAUDE_CONFIG_DIR/agents"

# Written beside, then renamed over, so a reader never sees half a file.
# `install -m 600`: the store copy is read-only.
instructions=$(mktemp "$CLAUDE_CONFIG_DIR/.CLAUDE.md.XXXXXX")
install -m 600 "$instructions_file" "$instructions"
mv "$instructions" "$CLAUDE_CONFIG_DIR/CLAUDE.md"

set -- --settings "$settings_file" "$@"
