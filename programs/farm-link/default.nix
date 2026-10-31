# factory-link-farm <dir> <farm>: rebuilds ~/.claude/<dir> as per-entry links
# into <farm>, without the wipe of the stock wrapper. Shared by the
# claude-factory wrapper and programs/software-factory, for `skills` and
# `agents`. Linux only: `mv --exchange`.
#
# The scratch directory is exchanged with the live one, so a path lookup never
# misses, and the previous links stay in `old` until the next run, so a reader
# that already opened them still lists every entry. A bare `claude-factory`
# takes no lock, so runs overlap: each fills a scratch of its own, and an
# exchange leaves every directory whole, so no run needs to wait for another.
{ pkgs }:

pkgs.writeShellApplication {
  name = "factory-link-farm";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    live="$HOME/.claude/$1" old="$HOME/.claude/.$1.old"
    mkdir -p "$live" "$old"
    scratch=$(mktemp -d "$HOME/.claude/.$1.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    ln -s "$2"/* "$scratch/"
    mv --exchange --no-target-directory "$scratch" "$live"
    mv --exchange --no-target-directory "$scratch" "$old"
  '';
}
