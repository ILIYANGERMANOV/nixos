{ root, pkgs, ... }:
let
  kotlin = import "${root}/programs/kotlin" { inherit pkgs; };
in
{
  home.packages = kotlin.workstation.packages;
  home.sessionVariables = kotlin.workstation.env;
}
