# The Android and Kotlin Multiplatform toolchain agents build with, global so
# that no repository needs a flake of its own. The Remote Control servers get
# the same environment in claude-factory.nix.
{ root, pkgs, ... }:
let
  kotlin = import "${root}/programs/kotlin" { inherit pkgs; };
in
{
  home = {
    inherit (kotlin.android) packages;
    sessionVariables = kotlin.android.env;
    file.".gradle/gradle.properties".source = kotlin.android.gradleProperties;
  };
}
