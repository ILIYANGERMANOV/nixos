# The linters, type checkers and test runners the tech checks run. Every check
# takes its tool from here and the repo dev shell puts all of them on PATH, so
# a command run by hand in `nix develop` meets the same versions CI does.
# Not `<tech>-<kind>` checks themselves, hence apart from default.nix.
{ pkgs }:
{
  # Test dependencies live only there: every script that ships runs on the
  # stdlib alone. mutmut too, so the mutation runner's tests import what it
  # imports and a mutant meets the same pytest the tests pass with.
  inherit (import ../mutation { inherit pkgs; }) python;

  inherit (pkgs)
    ruff
    basedpyright
    shellcheck
    actionlint
    ast-grep
    bats
    selene
    stylua
    biome
    ;
}
# hlint, fourmolu and cabal-fmt: the Haskell runners' own, so a check and a
# runner never meet different versions.
// (import ../haskell { inherit pkgs; }).tools
