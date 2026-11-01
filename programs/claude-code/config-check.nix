# checks.claude-config: the real configuration, where checks.claude-code tests
# the logic against synthetic input. It fails when a catalog skill is hidden from
# the model, and when a size passes its ceiling in budget.json. A rise there is
# the visible diff that says a change costs every agent more start-up context.
#
# Sizes are bytes of what the repository controls: a flavor's instructions, its
# model-invocable skill listing, and `loads`, what one kind of agent reads for its
# work. `.report` prints the table, passing or not (`just skill-budget`).
{
  pkgs,
  lib ? pkgs.lib,
  frontmatter,
  hiddenSkills,
  skillNames,
  flavors,
  loads,
  ceilings,
}:

let
  shellCheck = import ../shell-check { inherit pkgs; };

  hiddenCatalogSkills = lib.intersectLists hiddenSkills skillNames;

  # budget-compare <sizes> <ceilings.json>: prints sizes as a table and fails on
  # one over its ceiling. Sizes are `<ceiling key> <subject> <bytes>` lines. A
  # size with no ceiling, or a ceiling with no size, fails too, so every number
  # is checked and none is stale.
  compare = shellCheck.writeShellApplication {
    name = "budget-compare";
    runtimeInputs = [ pkgs.jq ];
    text = shellCheck.fragment ./budget-compare.sh;
  };

  sizes =
    pkgs.runCommand "claude-config-sizes"
      {
        nativeBuildInputs = [
          pkgs.gawk
          pkgs.yq-go
        ];
      }
      ''
        ${frontmatter}

        # What the session lists for each skill the model may invoke.
        listing() {
          for md in "$1"/*/SKILL.md; do
            fm=$(frontmatter "$md")
            if [ "$(yq '."disable-model-invocation" // false' <<<"$fm")" != true ]; then
              yq -r '.name + ": " + .description' <<<"$fm"
            fi
          done
        }

        ${lib.concatMapStrings (flavor: ''
          echo "instructions ${flavor.name} $(wc -c <${flavor.instructions})" >>"$out"
          echo "listing ${flavor.name} $(listing ${flavor.skillFarm} | wc -c)" >>"$out"
        '') flavors}
        ${lib.concatStrings (
          lib.mapAttrsToList (name: files: ''
            cat ${lib.concatMapStringsSep " " (file: lib.escapeShellArg "${file}") files} >load
            echo "${name} - $(wc -c <load)" >>"$out"
          '') loads
        )}
      '';

  report = pkgs.runCommand "claude-config-report" { nativeBuildInputs = [ compare ]; } ''
    budget-compare ${sizes} ${ceilings} >"$out" || true
  '';
in
assert lib.assertMsg (
  hiddenCatalogSkills == [ ]
) "skillOverrides hides catalog skill(s): ${toString hiddenCatalogSkills}";
pkgs.runCommand "claude-config-check"
  {
    nativeBuildInputs = [ compare ];
    passthru = { inherit report; };
  }
  ''
    # Given synthetic sizes, each way to break the budget must fail.
    echo '{"a": 10, "b": 10}' >ceilings.json
    rejects() {
      printf '%s' "$1" >bad-sizes
      if budget-compare bad-sizes ceilings.json >/dev/null 2>&1; then
        echo "budget-compare accepted: $1" >&2
        exit 1
      fi
    }
    rejects $'a x 11\nb x 10\n'
    rejects $'a x 10\nb x 10\nc x 1\n'
    rejects $'a x 10\n'
    printf 'a x 10\nb x 10\n' >good-sizes
    budget-compare good-sizes ceilings.json >/dev/null

    budget-compare ${sizes} ${ceilings} >"$out"
  ''
