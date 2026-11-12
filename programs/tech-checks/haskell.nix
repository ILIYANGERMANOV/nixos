# The Haskell kernel in programs/agents/kernel, the repo's only Haskell. Its
# source comes through the built package's `src`, by name: a path into another
# program breaks Deslop's programs-are-isolated.
{ pkgs, kernel }:
let
  tools = import ./tools.nix { inherit pkgs; };
in
{
  # The hspec suite runs in the package's checkPhase, so the package is the check.
  haskell-tests = kernel;

  # The format half repeats `just format --ci`, so a miss shows in this job too.
  # fourmolu reads fourmolu.yaml and state.cabal's extensions beside the source.
  haskell-lint =
    pkgs.runCommand "haskell-lint"
      {
        nativeBuildInputs = [
          tools.hlint
          tools.fourmolu
        ];
      }
      ''
        cd ${kernel.src}
        hlint .
        fourmolu --mode check app src test
        touch "$out"
      '';
}
