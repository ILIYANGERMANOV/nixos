# The /qa runtime's TypeScript in programs/playwright: Biome, tsc and Vitest.
# `checks.qa` is its end-to-end layer.
{ pkgs }:
let
  inherit (pkgs) lib;
  inherit (import ../playwright { inherit pkgs; }) typescript;

  lintSource = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../biome.json
      typescript.fileset
    ];
  };

  # `command` runs in the sources with `node_modules` installed.
  withDependencies =
    name: tools: command:
    pkgs.stdenvNoCC.mkDerivation {
      inherit name;
      inherit (typescript) src pnpmDeps;
      nativeBuildInputs = typescript.nativeBuildInputs ++ tools;
      buildPhase = ''
        runHook preBuild
        ${command}
        runHook postBuild
      '';
      installPhase = ''
        touch "$out"
      '';
    };
in
{
  ts-lint =
    pkgs.runCommand "ts-lint"
      {
        nativeBuildInputs = [ pkgs.biome ];
      }
      ''
        cd ${lintSource}
        biome ci --error-on-warnings --colors=off programs/playwright
        touch "$out"
      '';

  ts-types = withDependencies "ts-types" [ typescript.tsc ] "tsgo --noEmit -p .";

  ts-test = withDependencies "ts-test" [ ] "node_modules/.bin/vitest run";
}
