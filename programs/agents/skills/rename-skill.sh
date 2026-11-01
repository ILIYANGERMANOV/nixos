# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
cp -r --no-preserve=mode,ownership "$skill_source" "$out"
chmod -R u+w "$out"
awk -v new="$new_name" '
  NR == 1 && $0 == "---" { infm = 1; print; next }
  infm && $0 == "---"    { if (!seen) print "name: " new; infm = 0; print; next }
  infm && /^name:/       { print "name: " new; seen = 1; next }
                         { print }
' "$out/SKILL.md" >"$out/SKILL.md.new"
mv "$out/SKILL.md.new" "$out/SKILL.md"
