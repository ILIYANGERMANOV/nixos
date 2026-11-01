# shellcheck shell=bash
live="$HOME/.claude/skills"
mkdir -p "$live"
scratch=$(mktemp -d "$HOME/.claude/.skills.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
ln -s "$1"/* "$scratch/"
for link in "$scratch"/*; do
  mv --no-target-directory "$link" "$live/${link##*/}"
done
for entry in "$live"/*; do
  if [ -L "$entry" ] && [ ! -e "$1/${entry##*/}" ]; then
    rm -f "$entry"
  fi
done
