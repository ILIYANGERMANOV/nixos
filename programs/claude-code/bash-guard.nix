# A hook guard: a Python script built against hook_event.py and transcripts.py,
# so every guard finds its agent's transcript the same way. A guard that reads a
# command's structure sets `parsesCommands`, for bash_commands.py and the shfmt
# it brings into the closure.
{
  pkgs,
  name,
  script,
  parsesCommands ? false,
}:

let
  bashCommands = pkgs.replaceVars ./bash_commands.py { shfmt = pkgs.lib.getExe pkgs.shfmt; };

  guardModules = pkgs.python3Packages.toPythonModule (
    pkgs.runCommand "guard-modules" { } ''
      site=$out/${pkgs.python3.sitePackages}
      ${pkgs.lib.optionalString parsesCommands "install -Dm644 ${bashCommands} $site/bash_commands.py"}
      install -Dm644 ${./hook_event.py} $site/hook_event.py
      install -Dm644 ${./transcripts.py} $site/transcripts.py
      # The store cannot hold a cache written at run time, and a hook pays for
      # compiling on every tool call. Unchecked: a store path never changes.
      ${pkgs.python3.interpreter} -m compileall -q --invalidation-mode unchecked-hash $site
    ''
  );
in
rec {
  # flake8 off: `python-lint` and `python-types` are the Python gate.
  bin = pkgs.writers.writePython3Bin name {
    doCheck = false;
    libraries = [ guardModules ];
  } script;

  # The hook entry, for a flavor's matcher.
  hook = {
    type = "command";
    command = "${bin}/bin/${name}";
  };
}
