{ pkgs, claude }:
let
  inherit (pkgs) lib;

  # A path literal, not the flake's `self`: fileset refuses a store path string.
  root = ../..;

  shellCheck = import ../shell-check { inherit pkgs; };

  formatter = import ./formatter.nix { inherit pkgs; };

  typos = import ../typos { inherit pkgs; };
  yubikey = import ../yubikey-touch-sound { inherit pkgs; };

  # Same text and same shellcheck phase, without building what the text names:
  # keeping the context builds claude-code and `qa`'s browsers, 2.8 GiB against
  # 415 MiB, to lint one file nobody runs. Nothing goes unchecked, since the
  # guards and `qa` have checks of their own. The cost is that a script reached
  # only through such a reference stays unbuilt, so never use it on those.
  dry =
    drv:
    drv.overrideAttrs (old: {
      text = builtins.unsafeDiscardStringContext old.text;
    });

  source = fileset: lib.fileset.toSource { inherit root fileset; };

  # Every shell script in the repository, so a new one is covered by existing.
  # bats suites and their `load`ed helpers are shell too.
  shellFiles = lib.fileset.fileFilter (
    file:
    lib.any file.hasExt [
      "sh"
      "bats"
      "bash"
    ]
  ) root;
  justFiles = lib.fileset.unions [
    (root + "/Justfile")
    (lib.fileset.fileFilter (file: file.hasExt "just") (root + "/just"))
  ];

  githubSource = source (root + "/.github");
  shellSource = source shellFiles;
  justSource = source justFiles;
  formatSource = source (
    lib.fileset.unions [
      shellFiles
      justFiles
    ]
  );
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
        mapfile -d "" scripts < <(find . -type f -print0)
        [ "''${#scripts[@]}" -gt 0 ] || { echo "shell-lint: no scripts found" >&2; exit 1; }
        shellcheck ${lib.escapeShellArgs shellCheck.extraFlags} "''${scripts[@]}"
        touch "$out"
      '';

  # The shell inside the Justfile and its imports, which `--dump` flattens without
  # evaluating a backtick. Script names carry the recipe, as `<recipe>.sh` or
  # `<recipe>.line<N>.sh`. `{{ }}` next to sudo is text spliced into a root command.
  shell-just =
    pkgs.runCommand "shell-just"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.just
          pkgs.shellcheck
        ];
      }
      ''
        extract() { just --justfile "$1" --dump --dump-format json | jq -f ${./just-recipes.jq}; }
        splices() { jq -r '.path as $path | .sudoSplices[] | "\($path): \(.)"' "$1"; }

        extract ${./sudo-splices.just} > fixture.json
        splices fixture.json | diff - ${builtins.toFile "sudo-splices.expected" ''
          after-comment.sh: sudo echo __JUST_x__
          plain.line0.sh: sudo echo __JUST_x__
        ''}

        extract ${justSource}/Justfile > extracted.json

        [ -s extracted.json ] || { echo "shell-just: no recipes extracted" >&2; exit 1; }

        mkdir scripts
        jq --raw-output0 '.path, .text' extracted.json |
          while IFS= read -r -d "" path && IFS= read -r -d "" text; do
            printf '%s' "$text" > "scripts/$path"
          done

        status=0
        (cd scripts && shellcheck ${lib.escapeShellArgs shellCheck.extraFlags} -- *.sh) || status=1

        splices extracted.json > splices
        if [ -s splices ]; then
          cat splices >&2
          echo 'shell-just: {{ }} on a sudo line, use an exported parameter: `recipe $x:` then "$x"' >&2
          status=1
        fi

        [ "$status" -eq 0 ]
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
# Linux only: `llm-agents` has no x86_64-darwin package.
// lib.optionalAttrs pkgs.stdenv.isLinux {
  # The software factory's Claude policy (billing and permission mode), its
  # scripts through their bats suites against a real git, and its egress rules
  # through `nft --check`. It evaluates no host. Linux only, like the factory:
  # darwin's procps has no pgrep, which factory-ctl needs.
  shell-tests = import ../software-factory/check.nix { inherit pkgs; };

  # The writeShellApplication derivations no other check builds, so their
  # shellcheck phase runs without a host. Every flavor is listed through
  # `claude`, and the statusline's and yubikey's private scripts are reached
  # through references, which is why those two build for real.
  shell-embedded = pkgs.linkFarmFromDrvs "shell-embedded" (
    map dry (claude.packages ++ [ claude.factory.wrapper ])
    ++ [
      claude.statusline
      typos.cli
      yubikey.ssh
      yubikey.sshKeygen
    ]
  );
}
