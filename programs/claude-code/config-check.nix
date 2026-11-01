# checks.claude-config: the real configuration, where checks.claude-code tests
# the logic against synthetic input. It fails when a catalog skill is hidden from
# the model, and when a size passes its ceiling in budget.json. A rise there is
# the visible diff that says a change costs every agent more start-up context.
# It also holds the rendered subagents to their contract: an allowlist of tools
# with no MCP, only fields that are known, every preload installed, and the
# factory section in the factory's render alone.
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
  baseSkills,
  roleSkills,
  agentSources,
  factoryAgentSources,
  flavors,
  loads,
  ceilings,
}:

let
  hiddenCatalogSkills = lib.intersectLists hiddenSkills skillNames;

  # A preload Claude Code cannot find is skipped with only a debug-log line.
  uninstalledPreloads = lib.subtractLists baseSkills roleSkills;

  # budget-compare <sizes> <ceilings.json>: prints sizes as a table and fails on
  # one over its ceiling. Sizes are `<ceiling key> <subject> <bytes>` lines. A
  # size with no ceiling, or a ceiling with no size, fails too, so every number
  # is checked and none is stale.
  compare = pkgs.writeShellApplication {
    name = "budget-compare";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      sizes="$1" ceilings="$2" status=0
      printf '%-20s %-16s %8s %8s\n' metric subject bytes ceiling
      while read -r key subject bytes; do
        ceiling=$(jq -r --arg key "$key" '.[$key] // "none"' "$ceilings")
        verdict=""
        if [ "$ceiling" = none ] || [ "$bytes" -gt "$ceiling" ]; then
          verdict=" OVER"
          status=1
        fi
        printf '%-20s %-16s %8d %8s%s\n' "$key" "$subject" "$bytes" "$ceiling" "$verdict"
      done <"$sizes"
      for key in $(jq -r 'keys | .[]' "$ceilings"); do
        if ! grep -q "^$key " "$sizes"; then
          echo "$key: a ceiling nothing measures" >&2
          status=1
        fi
      done
      exit "$status"
    '';
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
assert lib.assertMsg (
  uninstalledPreloads == [ ]
) "subagents preload skill(s) not in baseSkills: ${toString uninstalledPreloads}";
pkgs.runCommand "claude-config-check"
  {
    nativeBuildInputs = [
      compare
      pkgs.yq-go
    ];
    passthru = { inherit report; };
  }
  ''
    ${frontmatter}

    # Claude Code ignores a field it does not know, and a misspelled `tools`
    # would quietly widen what the agent may do, hence the allowlist of fields.
    die() {
      echo "subagent $1: $2" >&2
      exit 1
    }
    check_agent() {
      fm=$(frontmatter "$2")
      [ "$(yq -r '.name // ""' <<<"$fm")" = "$1" ] || die "$1" "name differs from the file name"
      [ -n "$(yq -r '.description // ""' <<<"$fm")" ] || die "$1" "no description"
      tools=$(yq -r '.tools // ""' <<<"$fm")
      [ -n "$tools" ] || die "$1" "no tools allowlist"
      case "$tools" in
        *mcp__*) die "$1" "an MCP tool in its allowlist" ;;
      esac
      [ "$(yq -r '.omitClaudeMd // false' <<<"$fm")" = true ] || die "$1" "keeps CLAUDE.md"
      for field in $(yq -r 'keys | .[]' <<<"$fm"); do
        case "$field" in
          name | description | tools | omitClaudeMd | effort | model | skills) ;;
          *) die "$1" "unknown field $field" ;;
        esac
      done
    }
    ${lib.concatStrings (
      lib.mapAttrsToList (name: source: ''
        check_agent ${name} ${source}
        check_agent ${name} ${factoryAgentSources.${name}}
        if grep -q '^# Software factory$' ${source}; then
          die ${name} "the factory section reached another host"
        fi
        grep -q '^# Software factory$' ${factoryAgentSources.${name}} ||
          die ${name} "no factory section in the factory's render"
      '') agentSources
    )}

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
