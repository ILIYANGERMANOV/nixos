# The kernel of the agent flows (#351, plan #360): the Haskell `state` and
# `state-hook`, built with this repo's own haskellPackages so the cache guard
# sees no second GHC. Why Haskell: docs/adr/0018-category-model-haskell-state.md.
#
# Hand-written in cabal2nix's shape rather than callCabal2nix, which imports from
# a derivation, off on hosts and in CI (ADR 0009). So every dependency in
# state.cabal is named here too: one missing fails the build at once. The test
# suite runs in checkPhase, so building the package is `haskell-tests`.
{ pkgs }:
let
  inherit (pkgs) lib;
  # Through callPackage, not haskellPackages.mkDerivation directly:
  # justStaticExecutables overrides the `mkDerivation` argument.
  package =
    {
      mkDerivation,
      base,
      hedgehog,
      hspec,
      hspec-discover,
      hspec-golden,
      hspec-hedgehog,
      text,
    }:
    mkDerivation {
      pname = "state";
      version = "0.1.0.0";
      # The lint configs too, so `haskell-lint` reads the source through `src`.
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./state.cabal
          ./fourmolu.yaml
          ./.hlint.yaml
          ./app
          ./src
          ./test
        ];
      };
      isLibrary = true;
      isExecutable = true;
      libraryHaskellDepends = [
        base
        text
      ];
      executableHaskellDepends = [ base ];
      testHaskellDepends = [
        base
        hedgehog
        hspec
        hspec-golden
        hspec-hedgehog
        text
      ];
      testToolDepends = [ hspec-discover ];
      doCheck = true;
      # hspec-hedgehog seeds Hedgehog from hspec's seed: a fixed one makes a red
      # property replay the same on every machine.
      testFlags = [ "--seed=351" ];
      license = lib.licenses.mit;
      mainProgram = "state";
    };
in
pkgs.haskell.lib.compose.justStaticExecutables (pkgs.haskellPackages.callPackage package { })
