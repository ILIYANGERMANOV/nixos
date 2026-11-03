# Every .py in the repository against the root pyproject.toml.
{ pkgs, claude }:
let
  inherit (pkgs) lib;

  # A path literal, not the flake's `self`: fileset refuses a store path string.
  root = ../..;

  mutation = import ../mutation { inherit pkgs; };
  tools = import ./tools.nix { inherit pkgs; };

  pythonSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/pyproject.toml")
      # test_cache_check.py runs the real denylist.
      (root + "/just/cache-check/expensive-builds.deny")
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
        nativeBuildInputs = [ tools.ruff ];
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
        nativeBuildInputs = [ tools.basedpyright ];
      }
      ''
        cd ${pythonSource}
        HOME=$TMPDIR basedpyright --pythonpath ${lib.getExe tools.python}
        touch "$out"
      '';

  python-tests = pkgs.runCommand "python-tests" (
    mutation.testEnv
    // {
      nativeBuildInputs = [
        pkgs.git
        tools.python
      ];
      READ_GUARD = lib.getExe claude.guards.read;
      WAIT_GUARD = lib.getExe claude.guards.wait;
      SECRET_GUARD = lib.getExe claude.guards.secret;
      CONTEXT_GUARD = lib.getExe claude.guards.context;
      STATUSLINE = lib.getExe claude.statusline;
      PYTHON_SOURCE = pythonSource;
    }
  ) (builtins.readFile ./python-tests.sh);
}
