# The subagent definitions every flavor installs, and their check. A definition
# is the `<name>.md` Claude Code reads from ~/.claude/agents.
{
  pkgs,
  lib ? pkgs.lib,
  skillNames,
  frontmatter,
}:

let
  all = {
    researcher = ./researcher.md;
  };
in
{
  inherit all;

  # Claude Code ignores a misspelled field, and a misspelled `tools` would
  # quietly widen what the agent may do, hence the allowlist.
  check = pkgs.runCommand "subagents-check" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
    ${frontmatter}
    die() {
      echo "subagent $1: $2" >&2
      exit 1
    }
    check_agent() {
      fm=$(frontmatter "$2")
      [ "$(yq -r '.name // ""' <<<"$fm")" = "$1" ] || die "$1" "name differs from the file name"
      [ -n "$(yq -r '.description // ""' <<<"$fm")" ] || die "$1" "no description"
      for field in $(yq -r 'keys | .[]' <<<"$fm"); do
        case "$field" in
          name | description | tools | omitClaudeMd | effort | model | skills) ;;
          *) die "$1" "unknown field $field" ;;
        esac
      done
      for skill in $(yq -r '.skills // [] | .[]' <<<"$fm"); do
        case " ${toString skillNames} " in
          *" $skill "*) ;;
          *) die "$1" "preloads $skill, which is not in the skill catalog" ;;
        esac
      done
    }
    ${lib.concatStrings (lib.mapAttrsToList (name: path: "check_agent ${name} ${path}\n") all)}
    touch "$out"
  '';
}
