# The single door behind `nix fmt` and `just format`: one treefmt, one entry per
# language, so `just format --ci` enforces them all.
{ pkgs }:
let
  shellCheck = import ../shell-check { inherit pkgs; };

  # `just --fmt` at the root formats that one file and skips its imports, so an
  # imported file only gets formatted by naming it.
  justFormatEach = shellCheck.writeShellApplication {
    name = "just-format-each";
    runtimeInputs = [ pkgs.just ];
    text = ''
      for file in "$@"; do
        just --fmt --justfile "$file"
      done
    '';
  };
in
pkgs.treefmt.withConfig {
  runtimeInputs = [
    pkgs.nixfmt
    pkgs.shfmt
    justFormatEach
  ];
  settings = {
    # treefmt warns by default, too loud for a repo where most files have no formatter.
    on-unmatched = "info";
    formatter = {
      nixfmt = {
        command = "nixfmt";
        includes = [ "*.nix" ];
      };
      shfmt = {
        command = "shfmt";
        options = [
          "-i"
          "2"
          "-ci"
          "-w"
        ];
        includes = [ "*.sh" ];
      };
      just = {
        command = "just-format-each";
        includes = [
          "Justfile"
          "*.just"
        ];
      };
    };
  };
}
