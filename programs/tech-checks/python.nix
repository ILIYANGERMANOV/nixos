# Every .py in the repository against the root pyproject.toml.
{
  pkgs,
  claude,
  state,
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
      # the old scripts printed; test_flow.py holds the engineer's SKILL.md to
      # `state render`, its blockers.md to the stop rule and quality.md to the rows.
      (lib.fileset.fileFilter (
        file:
        file.hasExt "py"
        || builtins.elem file.name [
          "statusline-corpus.json"
          "SKILL.md"
          "blockers.md"
          "quality.md"
          # test_agent_hook.py holds the enums to the vocabulary Nix reads.
          "vocabulary.json"
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
      READ_GUARD = lib.getExe claude.guards.read;
      WAIT_GUARD = lib.getExe claude.guards.wait;
      SECRET_GUARD = lib.getExe claude.guards.secret;
      CONTEXT_GUARD = lib.getExe claude.guards.context;
      AGENT_HOOK_CLAUDE = lib.getExe claude.hookAdapter.bin;
      AGENT_HOOK_CLAUDE_TOOLS = claude.hookAdapter.toolsFile;
      STATUSLINE = lib.getExe claude.statusline;
      # test_e2e.py runs the wrapped `state` and `state-hook`, as the agents get them.
      STATE = lib.getExe state;
      STATE_HOOK = "${state}/bin/state-hook";
      PYTHON_SOURCE = pythonSource;
    }
  ) (builtins.readFile ./python-tests.sh);
}
