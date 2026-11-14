# The kernel of the agent flows (#351, plan #360): the Haskell `state` and
# `state-hook`, built with this repo's own haskellPackages so the cache guard
# sees no second GHC. Why Haskell: docs/adr/0018-category-model-haskell-state.md.
#
# The result is the installed command: both binaries wrapped with the step
# table, on PATH beside `ctx`. `passthru.hooks` is the hook module the base
# profile lists (hooks.nix); `passthru.package` the Haskell package itself;
# `passthru.tooling` its dev shell, runners and lint check (programs/haskell).
#
# Hand-written in cabal2nix's shape rather than callCabal2nix, which imports from
# a derivation, off on hosts and in CI (ADR 0009). So every dependency in
# state.cabal is named here too: one missing fails the build at once. The test
# suite runs in checkPhase, so building the package is `haskell-tests`.
# `steps` is the flows' step table as JSON (programs/agents/flows), which the
# suite holds equal to the kernel's steps. `vocabulary` is the hook contract's
# names (programs/agents/hooks/vocabulary.json), which the suite holds the hook's
# enums to.
{
  pkgs,
  # programs/haskell: the dev shell, runners and lint check.
  haskell,
  steps,
  vocabulary,
}:
let
  inherit (pkgs) lib;
  # What the suite reads from the environment, under the nix build, the cabal
  # runners and the ghcid session alike: the e2e spec runs both executables.
  testEnv = {
    env = {
      STATE_STEPS = steps;
      HOOK_VOCABULARY = vocabulary;
    };
    bins = {
      STATE_BIN = "state";
      STATE_HOOK_BIN = "state-hook";
    };
  };
  # hspec-hedgehog seeds Hedgehog from hspec's seed: a fixed one makes a red
  # property replay the same on every machine.
  testFlags = [ "--seed=351" ];
  # Through callPackage, not haskellPackages.mkDerivation directly:
  # justStaticExecutables overrides the `mkDerivation` argument.
  package =
    {
      mkDerivation,
      aeson,
      base,
      bytestring,
      containers,
      directory,
      effectful,
      filepath,
      hedgehog,
      hspec,
      hspec-discover,
      hspec-golden,
      hspec-hedgehog,
      process,
      temporary,
      text,
      time,
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
        aeson
        base
        bytestring
        containers
        directory
        effectful
        filepath
        process
        text
        time
      ];
      executableHaskellDepends = [
        base
        text
      ];
      testHaskellDepends = [
        aeson
        base
        bytestring
        containers
        directory
        effectful
        hedgehog
        hspec
        hspec-golden
        hspec-hedgehog
        filepath
        process
        temporary
        text
        time
      ];
      # git for the e2e spec's temp repos (State.E2ESpec).
      testToolDepends = [
        hspec-discover
        pkgs.git
      ];
      doCheck = true;
      inherit testFlags;
      preCheck = haskell.checkEnv testEnv;
      license = lib.licenses.mit;
      mainProgram = "state";
    };
  unwrapped = pkgs.haskellPackages.callPackage package { };
  built = pkgs.haskell.lib.compose.justStaticExecutables unwrapped;
  # They run the session's own git and gh, the ones the agent already works
  # with: the gh on PATH is the one logged in, so these only fill in for none.
  fallbackPath = lib.makeBinPath [
    pkgs.gh
    pkgs.git
  ];
in
pkgs.runCommand "state"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.mainProgram = "state";
    passthru = {
      hooks = ./hooks.nix;
      package = built;
      # The dev shell, runners and lint check (programs/haskell). Not `dev`:
      # stdenv takes a dependency's `dev` attribute as its dev output.
      tooling = haskell.mkPackage {
        name = "kernel";
        package = unwrapped;
        dir = "programs/agents/kernel";
        testSuite = "state-test";
        executables = [
          "state"
          "state-hook"
        ];
        inherit testEnv testFlags;
      };
    };
  }
  ''
    mkdir -p "$out/bin"
    for bin in state state-hook; do
      makeWrapper "${built}/bin/$bin" "$out/bin/$bin" \
        --set STATE_STEPS ${steps} \
        --suffix PATH : ${fallbackPath}
    done
  ''
