# A PreToolUse hook for Bash and Read that blocks a large file read. What it
# blocks, and its limit, are in read-guard.py; the scenarios are in
# test_read-guard.py.
{ pkgs }:

import ./bash-guard.nix {
  inherit pkgs;
  name = "claude-read-guard";
  parsesCommands = true;
  script = builtins.replaceStrings [ "@git@" ] [ "${pkgs.git}/bin/git" ] (
    builtins.readFile ./read-guard.py
  );
}
