# A PreToolUse hook for Bash that blocks a foreground wait. What it blocks is
# in wait-guard.py; the scenarios are in bash-guards-check.nix.
{ pkgs }:

import ./bash-guard.nix {
  inherit pkgs;
  name = "claude-wait-guard";
  script = builtins.readFile ./wait-guard.py;
}
