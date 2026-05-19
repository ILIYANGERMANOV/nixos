{ root, pkgs, lib, themeConfig, ... }:

let
  claude = import "${root}/programs/claude-code" { inherit pkgs lib; theme = themeConfig; };
in
{
  home.packages = claude.packages;

  home.activation.claudeCodeSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" ] claude.activationScript;
}
