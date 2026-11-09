# `state`: the engineer flow as an append-only event log, folded into the
# current state, with the next arrow advised. A Python package: main.py is the
# entry point, the other modules beside it hold the logic and each
# test_<module>.py runs it. It
# runs the session's own git and gh, the ones the agent already works with: the
# gh on PATH is the one logged in, so the package's gh only fills in for none.
#
# hook.py is a second entry point, `state-hook <name>`: the hooks hooks.nix
# declares, which record the run as the agents work (passthru.hooks, the file
# a profile lists).
{
  pkgs,
  # agent_hook.py as a Python library: the contract state-hook reads and prints.
  agentHook,
  # `ctx`, which state-hook runs for a diff reader's `Diff:` folder.
  ctx,
}:

let
  python = pkgs.python313;
  # A fallback after the session's own gh: see the header.
  ghPath = pkgs.lib.makeBinPath [ pkgs.gh ];
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
    passthru.hooks = ./hooks.nix;
  }
  ''
    mkdir -p "$out/lib/state" "$out/bin"
    cp ${modules}/*.py "$out/lib/state/"
    # -P: the working directory never shadows the package, as a `state/`
    # there would under plain `-m`.
    makeWrapper ${pkgs.lib.getExe python} "$out/bin/state" \
      --add-flags "-P -m state.main" \
      --set PYTHONPATH "$out/lib" \
      --suffix PATH : ${ghPath}
    makeWrapper ${pkgs.lib.getExe python} "$out/bin/state-hook" \
      --add-flags "-P -m state.hook" \
      --set PYTHONPATH "$out/lib:${agentHook}/${python.sitePackages}" \
      --prefix PATH : ${pkgs.lib.makeBinPath [ ctx ]} \
      --suffix PATH : ${ghPath}
  ''
