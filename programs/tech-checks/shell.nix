{ pkgs }:
let
  inherit (pkgs) lib;

  # A path literal, not the flake's `self`: fileset refuses a store path string.
  root = ../..;
in
{
  # Lints .github/workflows, and through nixpkgs' wrapped shellcheck every
  # `run:` block in them.
  shell-actionlint =
    pkgs.runCommand "shell-actionlint"
      {
        nativeBuildInputs = [ pkgs.actionlint ];
      }
      ''
        cd ${
          lib.fileset.toSource {
            inherit root;
            fileset = ../../.github;
          }
        }
        actionlint .github/workflows/*.yml
        touch "$out"
      '';
}
