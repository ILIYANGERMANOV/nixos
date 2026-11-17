# The blocks the skills paste from `state render` (#360, "Rendered and checked
# in"), held equal to what the built `state` prints, so the text cannot drift
# from what the kernel does. A Nix check rather than a case in the kernel's
# suite: the suite runs in the package's build, so reading the skill text there
# would rebuild the installed `state` on every prose edit.
#
# A table or quoted block must stand alone: blank lines around it, so a row
# added or dropped beside it fails too. The Fuel rows sit apart in their
# table, so each must be a whole line of it. An init line sits inline in a
# sentence, so it need only appear as a whole code span.
{
  pkgs,
  state,
  # The checked-in files that paste a block.
  engineer,
  tenX,
  architect,
  fuel,
}:
pkgs.runCommand "agents-rendered" { nativeBuildInputs = [ state ]; } ''
  fail() { echo "$1 drifted from \`state render $2\`; paste this:" >&2; cat "$3" >&2; exit 1; }

  # Exactly the rendered lines, between blank lines (or the file's start or end).
  block() {
    state render $2 > rendered
    text=$'\n\n'"$(cat "$1")"$'\n\n'
    want=$'\n\n'"$(cat rendered)"$'\n\n'
    [[ $text == *"$want"* ]] || fail "$1" "$2" rendered
  }

  # Each rendered line, as a whole line of the file.
  lines() {
    state render $2 > rendered
    while IFS= read -r line; do
      grep -Fxq -- "$line" "$1" || fail "$1" "$2" rendered
    done < rendered
  }

  # The rendered line as a whole code span, anywhere in the file.
  inline() {
    state render $2 > rendered
    grep -Fq -- "\`$(cat rendered)\`" "$1" || fail "$1" "$2" rendered
  }

  block ${engineer}/SKILL.md "states --flow engineer"
  block ${engineer}/references/blockers.md stop-rule
  block ${engineer}/references/blockers.md plan-wrong
  block ${engineer}/references/blockers.md kinds
  block ${tenX}/SKILL.md "states --flow 10x"
  block ${tenX}/SKILL.md kinds
  lines ${fuel} fuel
  inline ${engineer}/SKILL.md "init --flow engineer"
  inline ${tenX}/SKILL.md "init --flow 10x"
  block ${architect}/SKILL.md "states --flow architect"
  inline ${architect}/SKILL.md "init --flow architect"
  touch "$out"
''
