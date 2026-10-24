# A PreToolUse hook for Bash: blocks a command that `cat`s or `git show`s
# several files totalling over 8KB, and tells the model to grep first and read
# ranges instead. Fails open. The logic and its limits are in read-guard.py; the
# scenarios are in read-guard-check.nix.
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
