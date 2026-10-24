# A PreToolUse hook for Bash that blocks a large multi-file read. What it
# blocks, and its limit, are in read-guard.py; the scenarios are in
# read-guard-check.nix.
{ pkgs }:

let
  # E501: the substituted store path alone is longer than flake8 allows.
  bin = pkgs.writers.writePython3Bin "claude-read-guard" { flakeIgnore = [ "E501" ]; } (
    builtins.replaceStrings [ "@git@" ] [ "${pkgs.git}/bin/git" ] (builtins.readFile ./read-guard.py)
  );
in
{
  inherit bin;

  # The settings fragment that installs it, for a flavor's extraSettings.
  settings.hooks.PreToolUse = [
    {
      matcher = "Bash";
      hooks = [
        {
          type = "command";
          command = "${bin}/bin/claude-read-guard";
        }
      ];
    }
  ];
}
