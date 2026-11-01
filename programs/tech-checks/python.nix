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
      # test_cache_check.py runs the real denylist.
      (root + "/just/nix-darwin/expensive-builds.deny")
      # test_statusline.py holds the statusline to what the old scripts printed.
      (lib.fileset.fileFilter (file: file.hasExt "py" || file.name == "statusline-corpus.json") root)
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
        STATUSLINE = lib.getExe claude.statusline;
        STDLIB_PYTHON = lib.getExe pkgs.python3;
      }
      ''
        cd ${pythonSource}
        HOME=$TMPDIR HYPOTHESIS_STORAGE_DIRECTORY=$TMPDIR/hypothesis PYTHONDONTWRITEBYTECODE=1 pytest
        touch "$out"
      '';
}
