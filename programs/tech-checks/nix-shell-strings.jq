# Input: one `ast-grep scan --json=compact` array over nix-shell-strings.yml.
# Output: one {name, where, lines} per string. `lines` counts source lines between
# the `''` delimiters, less the blank line each delimiter leaves: blank lines and
# comments inside count, and a multi-line `${ }` counts as many lines as it spans.

# `split` gives [] for "", so a line may be null here.
def blank: (. // "") | test("^\\s*$");

def shellLines:
  ltrimstr("''")
  | rtrimstr("''")
  | split("\n")
  | if (.[0] | blank) then .[1:] else . end
  | if (.[-1] | blank) then .[:-1] else . end;

.[]
| {
  name: (.file | split("/")[-1] | rtrimstr(".nix")),
  where: "\(.file):\(.range.start.line + 1)",
  lines: (.text | shellLines | length)
}
