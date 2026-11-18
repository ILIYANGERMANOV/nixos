# shellcheck shell=bash
# relocate <tree> <out> <dir>: copies <tree> to <out> with every link
# resolved, and points the ~/.claude paths its text names at ~/<dir>.
#
# The rendered skills, roles and instructions name ~/.claude by hand, but
# claude-kategory runs Claude Code in ~/<dir>. The sources stay as they are;
# only this copy says where its files really are. A form of the path the
# rewrite does not know fails the build, so no file can send an agent to the
# user's own ~/.claude.
tree=$1 out=$2 dir=$3

cp -rL "$tree" "$out"
chmod -R u+w "$out"

# GNU sed leaves a file without a match byte for byte, binary or not.
find "$out" -type f -exec sed -i \
  -e "s|~/\.claude/|~/$dir/|g" \
  -e "s|\\\$HOME/\.claude/|\$HOME/$dir/|g" \
  -e "s|Path\.home() / \"\.claude\"|Path.home() / \"$dir\"|g" \
  {} +

# Wider than the rewrite: the home directory in any spelling, then `.claude`
# not followed by a name character, `-` or `.`, so `.claude-kategory`,
# `.claude.json` and a project's own `.claude/` do not match.
if grep -rnIE '(~|HOME\}?|home\(\))[/" ]{1,4}\.claude([^-.[:alnum:]_]|$)' "$out" >&2; then
  echo "relocate: the paths above still name ~/.claude" >&2
  exit 1
fi
