# A hook guard: a Python script built against bash_commands.py and
# transcripts.py, so every guard splits a command and finds its agent's
# transcript the same way.
{
  pkgs,
  name,
  script,
}:

let
  guardModules = pkgs.python3Packages.toPythonModule (
    pkgs.runCommand "guard-modules" { } ''
      site=$out/${pkgs.python3.sitePackages}
      install -Dm644 ${./bash_commands.py} $site/bash_commands.py
      install -Dm644 ${./transcripts.py} $site/transcripts.py
    ''
  );
in
rec {
  # E501: a substituted store path alone is longer than flake8 allows.
  bin = pkgs.writers.writePython3Bin name {
    flakeIgnore = [ "E501" ];
    libraries = [ guardModules ];
  } script;

  # The hook entry, for a flavor's matcher.
  hook = {
    type = "command";
    command = "${bin}/bin/${name}";
  };
}
