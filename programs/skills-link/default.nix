# factory-link-skills <farm>: rebuilds ~/.claude/skills as per-skill links into
# <farm>, without the wipe of the stock wrapper. Shared by the claude-factory
# wrapper and programs/software-factory. Linux only: `mv --exchange`.
#
# The scratch directory is exchanged with the live one, so a path lookup never
# misses, and the previous links stay in it until the next run, so a reader that
# already opened them still lists every skill.
{ pkgs }:

pkgs.writeShellApplication {
  name = "factory-link-skills";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    live="$HOME/.claude/skills" scratch="$HOME/.claude/.skills.old"
    rm -rf "$scratch"
    mkdir -p "$scratch" "$live"
    ln -s "$1"/* "$scratch/"
    mv --exchange --no-target-directory "$scratch" "$live"
  '';
}
