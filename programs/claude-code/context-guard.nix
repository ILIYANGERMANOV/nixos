# A PostToolUse hook that tells an agent its context is past the budget. Its
# limits are in context-guard.py; the scenarios are in test_context-guard.py.
{ pkgs }:

import ./bash-guard.nix {
  inherit pkgs;
  name = "claude-context-guard";
  script = builtins.readFile ./context-guard.py;
}
