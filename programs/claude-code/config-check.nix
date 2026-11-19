# checks.claude-config: the real configuration, where checks.claude-code tests
# the logic against synthetic input. It fails when a catalog skill is hidden from
# the model, and when a size passes its ceiling. A rise in a ceiling is the
# visible diff that says a change costs every agent more start-up context.
# It also holds the rendered subagents to their contract: an allowlist of tools
# with no MCP, only fields that are known, every preload installed, and the
# factory section in the factory's render alone, and every flavor's settings to
# running the state hooks and the guards through the adapter, and nothing else,
# and the factory's to denying the picker, as every question is text.
#
# Sizes are programs/agents' budget and budget/'s, each `<ceiling key> <subject>
# <bytes>` lines, against their ceilings in tokens merged. `.report` prints the table,
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
  # Each flavor's settings.json as its wrapper writes it, by flavor name.
  flavorSettings,
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
      pkgs.jq
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

    # The base profile's hooks reach every flavor: one adapter entry per event,
    # matched on the hooks' tools, every tool after one (the context guard),
    # all running one manifest, and no hook beside them. The secret guard runs
    # where a secret file is exported, which its Read deny rules mark.
    entries='.hooks | to_entries[] | .key as $event | .value[]'
    check_hooks() {
      [ "$(jq -c "[$entries | {event: \$event, matcher}]" "$2")" = \
        '[{"event":"PostToolUse","matcher":null},{"event":"PreToolUse","matcher":"Agent|Bash|Edit|Read|Skill|SubagentHandback|Write"},{"event":"SessionStart","matcher":"startup|resume|compact"},{"event":"Stop","matcher":null},{"event":"SubagentStart","matcher":null},{"event":"SubagentStop","matcher":null},{"event":"UserPromptExpansion","matcher":null}]' ] ||
        { echo "$1 settings: the hook entries differ" >&2; exit 1; }
      commands=$(jq -r "[$entries | .hooks[].command] | unique | .[]" "$2")
      case "$commands" in
        */bin/agent-hook-claude\ *\ *) ;;
        *) echo "$1 settings: a hook other than the adapter" >&2; exit 1 ;;
      esac
      [ "$(wc -l <<<"$commands")" = 1 ] ||
        { echo "$1 settings: more than one hook command" >&2; exit 1; }
      secret=
      if jq -e '.permissions.deny // [] | any(contains("/run/secrets/"))' "$2" >/dev/null; then
        secret='"secret-guard",'
      fi
      [ "$(jq -c 'map_values(map(.name))' "$(cut -d' ' -f3 <<<"$commands")")" = \
        '{"afterTool":["context-guard","state-bind","state-stop-call"],"agentStart":["state-begin-agent"],"agentStop":["state-stop"],"beforeTool":["state-begin-skill","state-handback","state-route","state-spawn",'"$secret"'"read-guard","wait-guard"],"promptExpansion":["state-begin-prompt"],"sessionStart":["state-resume"]}' ] ||
        { echo "$1 settings: the hooks differ" >&2; exit 1; }
    }
    ${lib.concatStrings (
      lib.mapAttrsToList (name: file: ''
        check_hooks ${name} ${file}
      '') flavorSettings
    )}

    # The factory asks every question as text: its settings deny the picker.
    jq -e '.permissions.deny | index("AskUserQuestion")' ${flavorSettings.claude-factory} >/dev/null ||
      { echo "claude-factory settings: AskUserQuestion is not denied" >&2; exit 1; }

    # Given synthetic byte sizes against token ceilings, each way to break the
    # budget must fail. 40 bytes is 10 tokens, 41 rounds up to 11.
    echo '{"a": 10, "b": 10}' >ceilings.json
    rejects() {
      printf '%s' "$1" >bad-sizes
      if budget-compare bad-sizes ceilings.json >/dev/null 2>&1; then
        echo "budget-compare accepted: $1" >&2
        exit 1
      fi
    }
    rejects $'a x 41\nb x 40\n'
    rejects $'a x 40\nb x 40\nc x 1\n'
    rejects $'a x 40\n'
    printf 'a x 40\nb x 40\n' >good-sizes
    budget-compare good-sizes ceilings.json >/dev/null

    budget-compare ${allSizes} ${allCeilings} >"$out"
  ''
