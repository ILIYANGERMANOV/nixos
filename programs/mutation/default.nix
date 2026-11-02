# Diff-scoped mutation testing: mutmut for the Python logic, StrykerJS for the
# /qa TypeScript logic, one report for both. A runner and never a flake check:
# it reads the git checkout and the network, which no sandboxed build can, and a
# check would run in `just tech`, `just quick-check` and `nix flake check`.
# See docs/adr/0010-mutation-testing.md.
{ pkgs }:
let
  shellCheck = import ../shell-check { inherit pkgs; };

  inherit (pkgs) lib;

  # nixpkgs has 3.2.0, which lacks the line index the report reads mutants with.
  # 3.8.1 pins click and libcst above nixpkgs by a minor version only.
  mutmut =
    ps:
    ps.buildPythonPackage {
      pname = "mutmut";
      version = "3.8.1";
      format = "wheel";
      pythonRelaxDeps = [
        "click"
        "libcst"
      ];
      src = pkgs.fetchurl {
        url = "https://files.pythonhosted.org/packages/18/0d/1885a8307b845e5b44ddf568939900819653e0168356ab94ed670b0e7ed0/mutmut-3.8.1-py3-none-any.whl";
        sha256 = "e424d72c0557b6a52a721d9b71e2d18eb9590af746db0bbad50b71e8d4d8ed78";
      };
      dependencies = [
        ps.click
        ps.coverage
        ps.libcst
        ps.pytest
        ps.setproctitle
        ps.textual
      ];
    };

  # The Python every test runs in: the `python-*` checks and mutmut alike, so a
  # mutant meets the same pytest and hypothesis the tests pass with.
  python = pkgs.python3.withPackages (ps: [
    ps.hypothesis
    ps.pytest
    (mutmut ps)
  ]);

  # What the Python tests read from the environment, here and in python-tests.
  testEnv = {
    STDLIB_PYTHON = lib.getExe pkgs.python3;
    # Not `BASH`: bash itself sets that one.
    BASH_ORACLE = lib.getExe pkgs.bash;
    SHFMT = lib.getExe pkgs.shfmt;
  };
in
{
  inherit python testEnv;

  runner = shellCheck.writeShellApplication {
    name = "mutation";
    runtimeInputs = [
      pkgs.git
      pkgs.nodejs
      pkgs.pnpm
    ];
    runtimeEnv = testEnv;
    text = ''exec ${lib.getExe python} ${./mutation_diff.py} "$@"'';
  };
}
