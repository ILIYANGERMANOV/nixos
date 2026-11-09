# `temp-factory [--capacity N] [dir]`: Remote Control from a Mac repo, steered
# from the Claude phone app, until Ctrl-C. macOS only: it calls Apple's
# caffeinate and pmset, and the host's `claude-pm` flavor from PATH.
{ pkgs }:

let
  shellCheck = import ../shell-check { inherit pkgs; };
in
{
  cli = shellCheck.writeShellApplication {
    name = "temp-factory";
    text = shellCheck.fragment ./temp-factory.sh;
  };
}
