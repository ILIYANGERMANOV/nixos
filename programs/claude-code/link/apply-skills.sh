# shellcheck shell=bash
# claude-apply-skills <claude dir> [farm]: rebuilds <claude dir>/skills as one
# link per skill of <farm>, or none without one. The caller passes link.sh's
# $claude_dir, so the dir is decided in one place.
#
# The directory is replaced wholesale rather than reconciled, so switching
# flavors can never leave a stale skill behind. The cost is that anything
# hand-placed in it is discarded on the next launch - prototype new skills in a
# project's .claude/skills instead, then commit them to
# programs/agents/skills/custom.
#
# Entries are per-skill symlinks into the store rather than one symlink for the
# whole directory: per-entry symlinks are what Claude Code documents support for.
skills="$1/skills"
rm -rf "$skills"
if [ $# -eq 2 ]; then
  mkdir -p "$skills"
  ln -s "$2"/* "$skills/"
fi
