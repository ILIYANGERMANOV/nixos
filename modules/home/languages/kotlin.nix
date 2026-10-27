{ root, pkgs, ... }:
let
  kotlin = import "${root}/programs/kotlin" { inherit pkgs; };
in
{
  home = {
    inherit (kotlin.workstation) packages;
    sessionVariables = kotlin.workstation.env;
  };
}
