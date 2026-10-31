# factory-link-skills <farm>: rebuilds ~/.claude/skills as per-skill links into
# <farm>, without the wipe of the stock wrapper. Shared by the claude-factory
# wrapper and programs/software-factory. Linux only: `mv --exchange`.
#
# The scratch directory is exchanged with the live one, so a path lookup never
# misses, and the previous links stay in `old` until the next run, so a reader
# that already opened them still lists every skill. A bare `claude-factory`
# takes no lock, so runs overlap: each fills a scratch of its own, and an
# exchange leaves every directory whole, so no run needs to wait for another.
{ pkgs }:

(import ../shell-check { inherit pkgs; }).writeShellApplication {
  name = "factory-link-skills";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    live="$HOME/.claude/skills" old="$HOME/.claude/.skills.old"
    mkdir -p "$live" "$old"
    scratch=$(mktemp -d "$HOME/.claude/.skills.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    ln -s "$1"/* "$scratch/"
    mv --exchange --no-target-directory "$scratch" "$live"
    mv --exchange --no-target-directory "$scratch" "$old"
  '';
}
