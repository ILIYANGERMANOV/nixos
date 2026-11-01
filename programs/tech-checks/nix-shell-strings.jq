# Input: one `ast-grep scan --json=compact` array over nix-shell-strings.yml.
# Output: one {where, lines} per string. `lines` counts source lines between
# the `''` delimiters, less the blank line each delimiter leaves: blank lines and
# comments inside count, and a multi-line `${ }` counts as many lines as it spans.

def shellLines:
  ltrimstr("''")
  | rtrimstr("''")
  | sub("\\A[ \t]*\n"; "")
  | sub("\n[ \t]*\\z"; "")
  | split("\n");

.[]
| {
  where: "\(.file):\(.range.start.line + 1)",
  lines: (.text | shellLines | length)
}
