# Input: `just --dump --dump-format json`. Output: one {path, text, sudoSplices}
# per script, as just would run it: a shebang recipe is one script, a linewise
# recipe one per line, since each line gets its own shell and joining them would
# hide a lost `cd` or variable. `{{ x }}` becomes the word __JUST_x__.

def fragment:
  if type == "string"
  then .
  else (.[0] | if .[0] == "variable" then .[1] else "expr" end) | "__JUST_\(.)__"
  end;

# The dump keeps a `\` continuation as two lines. Like just, drop the `\` and the
# next line's indent.
def logicalLines:
  reduce .[] as $line ([];
    if length > 0 and (.[-1] | endswith("\\"))
    then .[-1] = (.[-1] | rtrimstr("\\")) + ($line | sub("^\\s+"; ""))
    else . + [$line]
    end);

# A shell comment ends at its newline even after a `\`, so a comment line must
# go before joining, or it would swallow the sudo line below it.
def sudoSplices:
  split("\n")
  | map(select(test("^\\s*#") | not))
  | logicalLines
  | map(select(test("\\bsudo\\b") and test("__JUST_")));

.recipes
| to_entries[]
| .key as $name
| .value
| (.parameters | map(select(.export) | "export \(.name)=__JUST__\n") | join("")) as $prelude
| (.body | map(map(fragment) | join(""))) as $lines
| if .shebang
  then {
    path: "\($name).sh",
    text: "\($lines[0])\n\($prelude)\($lines[1:] | map("\(.)\n") | join(""))"
  }
  else
    $lines
    | logicalLines
    | map(sub("^[@-]+"; ""))
    | to_entries[]
    | select(.value | test("^\\s*(#|$)") | not)
    | {
      path: "\($name).line\(.key).sh",
      text: "#!/usr/bin/env bash\n\($prelude)\(.value)\n"
    }
  end
| . + {sudoSplices: (.text | sudoSplices)}
