# Every .py in the repository against the root pyproject.toml.
{
  pkgs,
  claude,
  guards,
}:
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
      # By name, not by path: a path into another program breaks Deslop's
      # programs-are-isolated. test_statusline.py holds the statusline to what
      # the old scripts printed.
      (lib.fileset.fileFilter (
        file:
        file.hasExt "py"
        || builtins.elem file.name [
          "statusline-corpus.json"
          # test_agent_hook.py holds the enums to the vocabulary Nix reads.
          "vocabulary.json"
          # test_guards.py shapes Claude's payloads as the contract recorded them.
          "snapshot.json"
        ]
      ) root)
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
      READ_GUARD = lib.getExe guards.read;
      WAIT_GUARD = lib.getExe guards.wait;
      SECRET_GUARD = lib.getExe guards.secret;
      CONTEXT_GUARD = lib.getExe guards.context;
      AGENT_HOOK_CLAUDE = lib.getExe claude.hookAdapter.bin;
      # Each flavor's settings.json by name, as installed: test_guards.py runs
      # the hook commands they hold, as Claude Code does.
      CLAUDE_SETTINGS = builtins.toJSON (
        lib.listToAttrs (
          map (flavor: lib.nameValuePair flavor.name "${flavor.settingsFile}") (
            claude.packages ++ [ claude.factory.wrapper ]
          )
        )
      );
      AGENT_HOOK_CLAUDE_TOOLS = claude.hookAdapter.toolsFile;
      STATUSLINE = lib.getExe claude.statusline;
      PYTHON_SOURCE = pythonSource;
    }
  ) (builtins.readFile ./python-tests.sh);
}
