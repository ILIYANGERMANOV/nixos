# checks.claude-config: the real configuration, where checks.claude-code tests
# the logic against synthetic input. It fails when a catalog skill is hidden from
# the model, and when a size passes its ceiling. A rise in a ceiling is the
# visible diff that says a change costs every agent more start-up context.
# It also holds the rendered subagents to their contract: an allowlist of tools
# with no MCP, only fields that are known, every preload installed, and the
# factory section in the factory's render alone.
#
# Sizes are programs/agents' budget and budget/'s, each `<ceiling key> <subject>
# <bytes>` lines, against their ceilings merged. `.report` prints the table,
# passing or not (`just skill-budget`).
{
  pkgs,
  lib ? pkgs.lib,
  frontmatter,
  hiddenSkills,
  skillNames,
  # Skills every flavor gets: the base profile's.
  baseProfileSkills,
  roleSkills,
  agentSources,
  factoryAgentSources,
  # budget-compare, see budget/.
  compare,
  sizes,
  ceilings,
}:

let
  hiddenCatalogSkills = lib.intersectLists hiddenSkills skillNames;

  # A preload Claude Code cannot find is skipped with only a debug-log line.
  uninstalledPreloads = lib.subtractLists baseProfileSkills roleSkills;

  allSizes = pkgs.concatText "claude-config-all-sizes" sizes;
  # The ceilings of both, where one key in two files is an error.
  allCeilings = pkgs.runCommand "claude-config-ceilings.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq -s 'if (map(keys) | add | length) == (add | length) then add
      else error("a ceiling key in two files") end' \
      ${lib.concatMapStringsSep " " (file: lib.escapeShellArg "${file}") ceilings} >"$out"
  '';

  report = pkgs.runCommand "claude-config-report" { nativeBuildInputs = [ compare ]; } ''
    budget-compare ${allSizes} ${allCeilings} >"$out" || true
  '';
in
assert lib.assertMsg (
  hiddenCatalogSkills == [ ]
) "skillOverrides hides catalog skill(s): ${toString hiddenCatalogSkills}";
assert lib.assertMsg (
  uninstalledPreloads == [ ]
) "subagents preload skill(s) not in the base profile: ${toString uninstalledPreloads}";
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

    budget-compare ${allSizes} ${allCeilings} >"$out"
  ''
