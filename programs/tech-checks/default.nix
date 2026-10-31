# Checks grouped by technology: a flat attrset of `<tech>-<kind>` derivations,
# since `checks.<system>.<name>` must be a derivation and cannot nest. The prefix
# is the group `just tech <tech>` builds. None may touch a host, so a group
# evaluates in seconds. See docs/adr/0009-tech-checks.md.
{ pkgs }:
import ./shell.nix { inherit pkgs; }
