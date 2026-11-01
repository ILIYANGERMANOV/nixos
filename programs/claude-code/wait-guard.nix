# A PreToolUse hook for Bash that blocks a foreground wait. What it blocks is
# in wait-guard.py; the scenarios are in test_wait-guard.py.
{ pkgs }:

import ./bash-guard.nix {
  inherit pkgs;
  name = "claude-wait-guard";
  parsesCommands = true;
  script = builtins.readFile ./wait-guard.py;
}
