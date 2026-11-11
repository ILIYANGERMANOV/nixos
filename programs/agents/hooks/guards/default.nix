# The guards: hook programs on the neutral contract (agent_hook.py) that stop
# an agent's accidents before they cost context or leak a secret. Each is a
# Python script in its folder, its rules and hint in its docstring, its
# scenarios in its test. hooks.nix declares them, a hook module the base
# profile lists.
#
# A guard that reads a command's structure gets bash_commands.py, with the
# shfmt it runs substituted as a store path: `replaceVars` fails the build on
# one left over, and the path brings shfmt into the closure.
{
  pkgs,
  # agent_hook.py as a Python library: the contract every guard reads and prints.
  agentHook,
}:

let
  inherit (pkgs) lib;

  bashCommands = pkgs.python3Packages.toPythonModule (
    pkgs.runCommand "bash-commands" { } ''
      site=$out/${pkgs.python3.sitePackages}
      install -Dm644 ${
        pkgs.replaceVars ./shared/bash_commands.py { shfmt = lib.getExe pkgs.shfmt; }
      } $site/bash_commands.py
      # A guard pays for compiling on every tool call, and the store cannot hold
      # a cache written at run time. Unchecked: a store path never changes.
      ${pkgs.python3.interpreter} -m compileall -q --invalidation-mode unchecked-hash $site
    ''
  );

  # flake8 off: `python-lint` and `python-types` are the Python gate.
  guard =
    name:
    {
      script,
      parsesCommands ? false,
    }:
    pkgs.writers.writePython3Bin name {
      doCheck = false;
      libraries = [ agentHook ] ++ lib.optional parsesCommands bashCommands;
    } script;
in
{
  read = guard "read-guard" {
    parsesCommands = true;
    script = builtins.replaceStrings [ "@git@" ] [ (lib.getExe pkgs.git) ] (
      builtins.readFile ./read-guard/read-guard.py
    );
  };
  wait = guard "wait-guard" {
    parsesCommands = true;
    script = builtins.readFile ./wait-guard/wait-guard.py;
  };
  secret = guard "secret-guard" { script = builtins.readFile ./secret-guard/secret-guard.py; };
  context = guard "context-guard" { script = builtins.readFile ./context-guard/context-guard.py; };

  # The hook module declaring them, for a profile's `hooks`.
  hooks = ./hooks.nix;
}
