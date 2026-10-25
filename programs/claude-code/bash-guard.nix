# A PreToolUse Bash guard: a Python script that exits 2 to block a call, built
# against bash_commands.py so every guard splits a command the same way.
{
  pkgs,
  name,
  script,
}:

let
  bashCommands = pkgs.python3Packages.toPythonModule (
    pkgs.runCommand "bash-commands" { } ''
      install -Dm644 ${./bash_commands.py} $out/${pkgs.python3.sitePackages}/bash_commands.py
    ''
  );
in
rec {
  # E501: a substituted store path alone is longer than flake8 allows.
  bin = pkgs.writers.writePython3Bin name {
    flakeIgnore = [ "E501" ];
    libraries = [ bashCommands ];
  } script;

  # The hook entry, for a flavor's PreToolUse Bash matcher.
  hook = {
    type = "command";
    command = "${bin}/bin/${name}";
  };
}
