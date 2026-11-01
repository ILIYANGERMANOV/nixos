# JetBrains' Kotlin language server, which nixpkgs does not package, from its
# official standalone release. The archive is a trimmed IntelliJ: a native
# launcher (`bin/intellij-server`), the platform jars and a bundled JetBrains
# Runtime. It needs that runtime's exact Java version, so it keeps it rather
# than running on a nixpkgs JDK; on Linux the launcher, the runtime and the
# few JNI libraries are patched to the store's loader instead.
#
# Bump: take the version from https://github.com/Kotlin/kotlin-lsp/releases
# and refresh both hashes with `nix store prefetch-file <url>`.
{ pkgs }:
let
  inherit (pkgs) lib stdenv;
  shellCheck = import ../shell-check { inherit pkgs; };

  version = "263.7084.0";
  base = "https://download.jetbrains.com/language-server/kotlin-server/${version}";

  archives = {
    x86_64-linux = {
      url = "${base}/kotlin-server-${version}.tar.gz";
      hash = "sha256-rgxLAeF6tzpKUienjqmebcvj5JlgAxWyJ1mk5M3dEd8=";
    };
    aarch64-darwin = {
      url = "${base}/kotlin-server-${version}-aarch64.sit";
      hash = "sha256-tAO/ilS9RY47pnMc+KuzNAvgi0OcA1dt/AKxP682lLg=";
    };
  };

  system = stdenv.hostPlatform.system;
  archive = archives.${system} or (throw "kotlin-lsp: no release archive pinned for ${system}");
in
stdenv.mkDerivation {
  pname = "kotlin-lsp";
  inherit version;

  src = pkgs.fetchurl archive;

  # The macOS archive is a zip under a `.sit` name, which stdenv does not
  # recognise.
  unpackCmd = lib.optionalString stdenv.isDarwin "unzip -q $curSrc";

  nativeBuildInputs = [
    pkgs.makeWrapper
  ]
  ++ lib.optionals stdenv.isDarwin [ pkgs.unzip ]
  ++ lib.optionals stdenv.isLinux [ pkgs.autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.isLinux [
    stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.freetype
    pkgs.alsa-lib
  ];

  # The runtime's AWT and Wayland toolkits. A language server is headless
  # and never loads them.
  autoPatchelfIgnoreMissingDeps = [
    "libX11.so.6"
    "libXext.so.6"
    "libXi.so.6"
    "libXrender.so.1"
    "libXtst.so.6"
    "libwayland-client.so.0"
    "libwayland-cursor.so.0"
    "libxkbcommon.so.0"
    "libgtk-3.so.0"
    "libgdk-3.so.0"
    "libgobject-2.0.so.0"
    "libglib-2.0.so.0"
    "libgio-2.0.so.0"
    "libdbus-1.so.3"
    "libEGL.so.1"
    "libGL.so.1"
  ];

  dontConfigure = true;
  dontBuild = true;
  # Stripping would break the runtime's signed and checksummed binaries.
  dontStrip = true;

  installPhase = shellCheck.fragment ./lsp-install.sh;

  meta = {
    description = "Kotlin language server by JetBrains";
    homepage = "https://github.com/Kotlin/kotlin-lsp";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames archives;
    mainProgram = "kotlin-lsp";
  };
}
