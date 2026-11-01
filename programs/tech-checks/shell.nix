{ pkgs, claude }:
let
  inherit (pkgs) lib;

  # A path literal, not the flake's `self`: fileset refuses a store path string.
  root = ../..;

  shellCheck = import ../shell-check { inherit pkgs; };

  # What `shell-limits` lets past: a recipe's name or a Nix file's stem.
  shellLimitExempt = [
    "statusline" # t12 removes it
    "_cache-check" # t12 removes it
  ];

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
  shellFiles = lib.fileset.fileFilter (file: file.hasExt "sh") root;
  justFiles = lib.fileset.unions [
    (root + "/Justfile")
    (lib.fileset.fileFilter (file: file.hasExt "just") (root + "/just"))
  ];
  # `check.nix` holds a program's test fakes, and the fixture is only ever that.
  nixFiles = lib.fileset.fileFilter (
    file:
    file.hasExt "nix"
    && !lib.elem file.name [
      "check.nix"
      "shell-limits-check.nix"
    ]
  ) root;

  githubSource = source (root + "/.github");
  shellSource = source shellFiles;
  justSource = source justFiles;
  nixSource = source nixFiles;
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
        mapfile -d "" scripts < <(find . -name '*.sh' -print0)
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

  # Shell past a limit belongs in a `.sh`, which every other check here can see.
  # A recipe counts all its body lines, a Nix string what nix-shell-strings.jq
  # counts in the sinks nix-shell-strings.yml names. The fixtures prove both
  # boundaries on every run. See docs/adr/0009-tech-checks.md.
  shell-limits =
    pkgs.runCommand "shell-limits"
      {
        nativeBuildInputs = [
          pkgs.ast-grep
          pkgs.jq
          pkgs.just
        ];
      }
      ''
        recipes() {
          just --justfile "$1" --dump --dump-format json |
            jq '.recipes | to_entries[] | {name: .key, where: .key, lines: (.value.body | length)}'
        }
        strings() {
          (cd "$1" && ast-grep scan --rule ${./nix-shell-strings.yml} --json=compact .) |
            jq -f ${./nix-shell-strings.jq}
        }
        over() {
          jq -r --argjson limit "$1" --argjson exempt ${lib.escapeShellArg (builtins.toJSON shellLimitExempt)} \
            'select(.lines > $limit and (.name | IN($exempt[]) | not)) | "\(.where): \(.lines) lines"' |
            sort -V
        }
        report() {
          [ -s "$1" ] || return 0
          cat "$1" >&2
          echo "shell-limits: $2" >&2
          status=1
        }

        recipes ${./shell-limits.just} | over 30 | diff - ${builtins.toFile "shell-limits-just.expected" ''
          over-limit: 31 lines
          shebang-over-limit: 31 lines
        ''}

        mkdir fixture
        cp ${./shell-limits-check.nix} fixture/shell-limits-check.nix
        strings fixture | over 5 | diff - ${builtins.toFile "shell-limits-nix.expected" ''
          shell-limits-check.nix:103: 6 lines
          shell-limits-check.nix:111: 6 lines
          shell-limits-check.nix:119: 6 lines
          shell-limits-check.nix:127: 6 lines
          shell-limits-check.nix:137: 6 lines
          shell-limits-check.nix:146: 6 lines
          shell-limits-check.nix:154: 6 lines
          shell-limits-check.nix:162: 6 lines
          shell-limits-check.nix:170: 6 lines
          shell-limits-check.nix:178: 6 lines
          shell-limits-check.nix:186: 6 lines
          shell-limits-check.nix:194: 6 lines
        ''}

        recipes ${justSource}/Justfile | over 30 > recipes
        strings ${nixSource} | over 5 > strings

        status=0
        report recipes "recipe over 30 lines, move to a .sh"
        report strings "Nix shell string over 5 lines, move to a .sh and read it in with readFile"

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
