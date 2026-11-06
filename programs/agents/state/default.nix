# `state`: the engineer flow as an append-only event log, folded into the
# current state, with the next arrow advised. main.py is the entry point, the
# other modules beside it hold the logic and each test_<module>.py runs it. It
# runs the session's own git, the one the agent already works with.
{ pkgs }:

let
  python = pkgs.python313;
  # The program's modules only: its tests and their helpers stay out of the store.
  modules = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.fileFilter (
      file:
      file.hasExt "py"
      && !pkgs.lib.hasPrefix "test_" file.name
      && !builtins.elem file.name [
        "conftest.py"
        "state_fixtures.py"
      ]
    ) ./.;
  };
in
# No lint or test here: `python-lint`, `python-types` and `python-tests` are the
# Python gate.
pkgs.runCommand "state"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.mainProgram = "state";
  }
  ''
    mkdir -p "$out/lib/state" "$out/bin"
    cp ${modules}/*.py "$out/lib/state/"
    makeWrapper ${pkgs.lib.getExe python} "$out/bin/state" \
      --add-flags "$out/lib/state/main.py" \
      --set PYTHONPATH "$out/lib/state"
  ''
