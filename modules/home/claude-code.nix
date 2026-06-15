{ root, inputs, pkgs, lib, themeConfig, ... }:

let
  claude = import "${root}/lib/claude-code.nix" {
    inherit root pkgs inputs lib;
    theme = themeConfig;
  };
in
{
  home.packages = claude.packages;

  home.activation.claudeCodeSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" ] claude.activationScript;
}
