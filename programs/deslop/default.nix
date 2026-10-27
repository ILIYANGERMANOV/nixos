# Deslop - an architecture linter that checks this repo's module graph against
# the rules in deslop/rules/ - https://github.com/Ivy-Apps/deslop
#
# Upstream ships no Nix package. Its npm release is a wrapper that dispatches to
# one package per platform, each holding a single static binary, so this fetches
# that platform tarball directly and skips npm entirely.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  version = "0.12.1";

  # Nix system -> npm platform package suffix and the tarball's hash.
  platforms = {
    x86_64-linux = {
      npm = "linux-x64";
      hash = "sha256-pF8tRRBKXMk9kboH5QMWsxYVvz0Wr2hRzcgJrECmaXE=";
    };
    aarch64-linux = {
      npm = "linux-arm64";
      hash = "sha256-cS9aBt9E1L6vYYeaVtcMMvMH1zBakXD0ai610U7WtkY=";
    };
    aarch64-darwin = {
      npm = "darwin-arm64";
      hash = "sha256-KnUmIlqBkLWOyz5FP3MoOmOeUAuiAYPofcImLiPNQNQ=";
    };
  };

  inherit (pkgs.stdenv.hostPlatform) system;
  platform = platforms.${system} or (throw "deslop: no release binary for ${system}");
in
{
  package = pkgs.stdenvNoCC.mkDerivation {
    pname = "deslop";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@ivy-apps/deslop-${platform.npm}/-/deslop-${platform.npm}-${version}.tgz";
      inherit (platform) hash;
    };

    # npm tarballs unpack into ./package.
    sourceRoot = "package";
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 bin/deslop $out/bin/deslop
      runHook postInstall
    '';

    meta = {
      description = "Architecture linter for a codebase's module graph";
      homepage = "https://deslop.dev";
      license = lib.licenses.mit;
      mainProgram = "deslop";
      platforms = builtins.attrNames platforms;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
}
