# Kotlin and Android, in two layers.
#
# `workstation` is what every host gets: a JDK for Gradle, the editor's
# language server and formatter, and adb to talk to a device. Projects bring
# their own Gradle through the wrapper and their own Kotlin through it.
#
# `android` adds what building Android and Kotlin Multiplatform projects needs
# without a per-repo flake: a shared Android SDK in the store, the compilers
# agents call directly, and Gradle settings sized for a small box.
{ pkgs }:
let
  jdk = pkgs.jdk17;
  # For projects whose Gradle toolchain asks for 21. Never on PATH, where its
  # `java` would collide with the default's: Gradle finds it through
  # `org.gradle.java.installations.paths`.
  jdk21 = pkgs.jdk21;

  # Accepted here rather than in nixpkgs' config, so only what uses this SDK
  # accepts its licence.
  sdk = (pkgs.androidenv.override { licenseAccepted = true; }).composeAndroidPackages {
    platformVersions = [
      "35"
      "36"
    ];
    buildToolsVersions = [
      "35.0.0"
      "36.0.0"
    ];
    includeEmulator = false;
    includeSystemImages = false;
    includeNDK = false;
    includeCmake = false;
  };
  sdkRoot = "${sdk.androidsdk}/libexec/android-sdk";

  workstationEnv = {
    JAVA_HOME = jdk.home;
  };
in
{
  workstation = {
    packages = [
      jdk
      (import ./lsp.nix { inherit pkgs; })
      pkgs.ktlint
      pkgs.android-tools
    ];
    env = workstationEnv;
  };

  android = {
    packages = [
      pkgs.kotlin
      pkgs.detekt
    ];

    env = workstationEnv // {
      ANDROID_HOME = sdkRoot;
      ANDROID_SDK_ROOT = sdkRoot;
      # AGP runs the aapt2 it downloads from Maven, a dynamically linked binary
      # built for a standard distribution. The SDK's own is patched for Nix.
      GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkRoot}/build-tools/36.0.0/aapt2";
    };

    # One Gradle JVM doing everything: the Kotlin compiler runs inside it
    # rather than in a daemon of its own, and tasks run one at a time. Two
    # daemons running Android lint ran a 7.7 GB box out of memory; one 4 GB
    # JVM passed. An idle daemon gives its memory back after 15 minutes.
    gradleProperties = pkgs.writeText "gradle.properties" ''
      org.gradle.jvmargs=-Xmx4g -XX:+UseParallelGC
      kotlin.compiler.execution.strategy=in-process
      org.gradle.parallel=false
      org.gradle.daemon.idletimeout=900000
      org.gradle.java.installations.paths=${jdk.home},${jdk21.home}
    '';

    # What the Kotlin/Native toolchain Gradle downloads into ~/.konan links
    # against, beyond nix-ld's defaults: its LLVM wants the old libtinfo.
    nixLdLibraries = [
      pkgs.ncurses5
      pkgs.zlib
      pkgs.stdenv.cc.cc.lib
    ];
  };
}
