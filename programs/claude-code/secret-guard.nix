# A PreToolUse hook for Bash that blocks the obvious shell routes to a
# protected secret file: protection against accidental reads, not a security
# boundary. What it blocks is in secret-guard.py; the scenarios are in
# test_secret-guard.py.
{ pkgs }:

let
  guard = import ./bash-guard.nix {
    inherit pkgs;
    name = "claude-secret-guard";
    script = builtins.readFile ./secret-guard.py;
  };
in
{
  inherit (guard) bin;

  # The hook entry guarding `files`, env var -> decrypted-file path.
  hookFor = files: {
    type = "command";
    command = "${guard.bin}/bin/claude-secret-guard ${
      pkgs.lib.escapeShellArg (
        builtins.toJSON {
          paths = builtins.attrValues files;
          vars = builtins.attrNames files;
        }
      )
    }";
  };
}
