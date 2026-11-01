# factory-link-skills <farm>: updates ~/.claude/skills to per-skill links into
# <farm>, without the wipe of the stock wrapper. Shared by the claude-factory
# wrapper and programs/software-factory.
#
# The directory is updated in place and never replaced, for two reasons. A
# reader lists a directory it opened earlier, and deleting a replaced directory
# empties it under that reader, however atomic the swap of its path was.
# Claude Code also keeps a real directory here, `synced`, which is why only
# links are removed.
#
# Each link is renamed over its old self, so a path lookup never misses, and
# stale links go last, so the directory is never empty. A bare `claude-factory`
# takes no lock, so runs overlap: that holds because generations of the farm
# share skills, and such a mix of two farms lasts until the next relink.
{ pkgs }:

let
  shellCheck = import ../shell-check { inherit pkgs; };
in
shellCheck.writeShellApplication {
  name = "factory-link-skills";
  runtimeInputs = [ pkgs.coreutils ];
  text = shellCheck.fragment ./link-skills.sh;
}
