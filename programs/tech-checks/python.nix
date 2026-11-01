# Every .py in the repository against the root pyproject.toml. Test dependencies
# stay in `testPython`: every script that ships runs on the stdlib alone.
{ pkgs, claude }:
let
  inherit (pkgs) lib;

  # A path literal, not the flake's `self`: fileset refuses a store path string.
  root = ../..;

  testPython = pkgs.python3.withPackages (ps: [
    ps.hypothesis
    ps.pytest
  ]);

  pythonSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/pyproject.toml")
      (lib.fileset.fileFilter (file: file.hasExt "py") root)
    ];
  };
in
{
  # The format half repeats `just format --ci`, so a miss shows in this job too.
  python-lint =
    pkgs.runCommand "python-lint"
      {
        nativeBuildInputs = [ pkgs.ruff ];
      }
      ''
        cd ${pythonSource}
        ruff check --no-cache .
        ruff format --no-cache --check .
        touch "$out"
      '';

  python-types =
    pkgs.runCommand "python-types"
      {
        nativeBuildInputs = [ pkgs.basedpyright ];
      }
      ''
        cd ${pythonSource}
        HOME=$TMPDIR basedpyright --pythonpath ${lib.getExe testPython}
        touch "$out"
      '';

  python-tests =
    pkgs.runCommand "python-tests"
      {
        nativeBuildInputs = [
          pkgs.git
          testPython
        ];
        READ_GUARD = lib.getExe claude.guards.read;
        WAIT_GUARD = lib.getExe claude.guards.wait;
        SECRET_GUARD = lib.getExe claude.guards.secret;
        CONTEXT_GUARD = lib.getExe claude.guards.context;
        STDLIB_PYTHON = lib.getExe pkgs.python3;
      }
      ''
        # A test imports bash_commands.py from source, so it gets what a guard gets.
        cp -r ${pythonSource} source
        chmod -R u+w source
        cd source
        substituteInPlace programs/claude-code/bash_commands.py \
          --replace-fail @shfmt@ ${lib.getExe pkgs.shfmt}
        HOME=$TMPDIR HYPOTHESIS_STORAGE_DIRECTORY=$TMPDIR/hypothesis PYTHONDONTWRITEBYTECODE=1 pytest
        touch "$out"
      '';
}
