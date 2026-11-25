# shellcheck shell=bash
# relocate <tree> <out>: copies <tree> to <out> with every link resolved,
# points the ~/.claude paths its text names at <out>, and each skill's
# ${CLAUDE_SKILL_DIR} at that skill's folder under <out>/skills.
#
# The twin of programs/claude-code/kategory/relocate.sh, which points the same
# paths at a dir under $HOME. OpenCode reads this config dir from the store,
# so here they name the store. Kept apart so no Claude Code build changes;
# merging the two is a follow-up. A form of the path the rewrite does not know
# fails the build, so no file can send an agent to the user's own ~/.claude.
set -euo pipefail
tree=$1 out=$2

cp -rL "$tree" "$out"
chmod -R u+w "$out"

# GNU sed leaves a file without a match byte for byte, binary or not.
find "$out" -type f -exec sed -i \
  -e "s|~/\.claude/|$out/|g" \
  -e "s|\\\$HOME/\.claude/|$out/|g" \
  -e "s|Path\.home() / \"\.claude\"|Path(\"$out\")|g" \
  {} +

# Claude Code expands ${CLAUDE_SKILL_DIR} when it loads a skill; OpenCode
# does not, and a shell would expand it to nothing.
shopt -s nullglob
for skill in "$out"/skills/*/; do
  find "$skill" -type f -exec sed -i "s|\${CLAUDE_SKILL_DIR}|${skill%/}|g" {} +
done

# Wider than the rewrite: the home directory in any spelling, then `.claude`
# not followed by a name character, `-` or `.`, so `.claude.json` and a
# project's own `.claude/` do not match; and the skill dir variable anywhere,
# such as outside a skill. grep exits 1 on no match and 2 on an error, which
# must not pass as "no leftover".
status=0
grep -rnIE '(~|HOME\}?|home\(\))[]/", ]{1,5}\.claude([^-.[:alnum:]_]|$)|CLAUDE_SKILL_DIR' "$out" >&2 || status=$?
case $status in
  1) ;;
  0)
    echo "relocate: the paths above still name ~/.claude" >&2
    exit 1
    ;;
  *)
    echo "relocate: could not search $out" >&2
    exit "$status"
    ;;
esac
