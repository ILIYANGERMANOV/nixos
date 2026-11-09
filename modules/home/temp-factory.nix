{
  root,
  pkgs,
  lib,
  ...
}:
let
  tempFactory = import "${root}/programs/temp-factory" { inherit pkgs; };
in
{
  # macOS only: it needs Apple's caffeinate and pmset.
  home.packages = lib.mkIf pkgs.stdenv.isDarwin [ tempFactory.cli ];
}
