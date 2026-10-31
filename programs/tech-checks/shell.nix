{ pkgs }:
let
  inherit (pkgs) lib;

  # A path literal, not the flake's `self`: fileset refuses a store path string.
  root = ../..;

  shellCheck = import ../shell-check { inherit pkgs; };

  formatter = import ./formatter.nix { inherit pkgs; };

  githubSource = lib.fileset.toSource {
    inherit root;
    fileset = root + "/.github";
  };

  # Every shell script in the repository, so a new one is covered by existing.
  shellSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.fileFilter (file: file.hasExt "sh") root;
  };

  formatSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.fileFilter (
      file: file.hasExt "sh" || file.hasExt "just" || file.name == "Justfile"
    ) root;
  };
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
        cd ${githubSource}
        actionlint .github/workflows/*.yml
        touch "$out"
      '';

  # The fragments as they stand. What crosses fragments is left to the assembled
  # scripts, which writeShellApplication checks with the same flags.
  shell-lint =
    pkgs.runCommand "shell-lint"
      {
        nativeBuildInputs = [ pkgs.shellcheck ];
      }
      ''
        cd ${shellSource}
        mapfile -d "" scripts < <(find . -name '*.sh' -print0)
        [ "''${#scripts[@]}" -gt 0 ] || { echo "shell-lint: no scripts found" >&2; exit 1; }
        shellcheck ${lib.escapeShellArgs shellCheck.extraFlags} "''${scripts[@]}"
        touch "$out"
      '';

  # `just format --ci` over the shell and just files alone, so it needs no host
  # and no Nix. treefmt rewrites in place, hence the writable copy.
  shell-format =
    pkgs.runCommand "shell-format"
      {
        nativeBuildInputs = [ formatter ];
      }
      ''
        cp -r --no-preserve=mode ${formatSource} tree
        if ! treefmt --ci --tree-root "$PWD/tree"; then
          diff -ru ${formatSource} tree >&2 || true
          echo "shell-format: not formatted, run just format" >&2
          exit 1
        fi
        touch "$out"
      '';
}
