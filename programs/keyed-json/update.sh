# shellcheck shell=bash
# `keyed-json-update <file> <filter> <values.json>`: sets the keys jq's
# <filter> writes in a JSON <file> another tool also writes, the Keyed class of
# .claude/rules/reproducibility.md, and leaves every other key as found. The
# filter reads <values.json> as `$nix[0]`. A missing file starts as {}; the
# result replaces it with one rename, so a reader never sees half a file.

file=$1
filter=$2
values=$3

mkdir -p "$(dirname "$file")"
[ -f "$file" ] || echo '{}' >"$file"
tmp=$(mktemp "$file.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq --slurpfile nix "$values" "$filter" "$file" >"$tmp"
mv "$tmp" "$file"
