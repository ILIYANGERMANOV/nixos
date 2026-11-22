# `keyed-json-update`: sets the Nix-owned keys of a JSON file another tool also
# writes, for every program that presets such a file (update.sh).
{ pkgs }:

let
  shellCheck = import ../shell-check { inherit pkgs; };
in
shellCheck.writeShellApplication {
  name = "keyed-json-update";
  runtimeInputs = [ pkgs.jq ];
  text = shellCheck.fragment ./update.sh;
}
