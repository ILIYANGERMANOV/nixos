# Sizes only Claude Code's format adds to the budget programs/agents measures
# (lib/passes/budget.nix): the skill listing a flavor sends on every call, and
# each rendered subagent's frontmatter. Ceilings in budget.json. And
# skillOverrides, which keeps the listing small.
{
  pkgs,
  lib,
  # Shell function: `frontmatter <file>` prints the YAML between its fences.
  frontmatter,
}:

let
  shellCheck = import ../../shell-check { inherit pkgs; };
in
{
  # budget-compare <sizes> <ceilings.json>: prints sizes as a table and fails on
  # one over its ceiling. Sizes are `<ceiling key> <subject> <bytes>` lines. A
  # size with no ceiling, or a ceiling with no size, fails too, so every number
  # is checked and none is stale.
  compare = shellCheck.writeShellApplication {
    name = "budget-compare";
    runtimeInputs = [ pkgs.jq ];
    text = shellCheck.fragment ./budget-compare.sh;
  };

  # The skill listing goes out on every call, and nothing here was ever invoked
  # by a factory agent. user-invocable-only hides a skill from the model and
  # keeps /name. Claude.ai's synced skills are keyed with their anthropic-skills:
  # prefix, bundled ones without. checks.claude-config fails if a catalog skill
  # lands on this list.
  skillOverrides = lib.genAttrs (
    map (name: "anthropic-skills:${name}") [
      "built-in-browser"
      "chrome-browser"
      "computer-use"
      "deep-research"
      "docs"
      "docx"
      "google-workspace"
      "import-memory"
      "morning"
      "pptx"
      "skill-creator"
      "xlsx"
    ]
    ++ [
      "code-review"
      "dataviz"
      "fewer-permission-prompts"
      "init"
      "keybindings-help"
      "loop"
      "plugin-authoring"
      "run"
      "schedule"
      "security-review"
      "simplify"
      "update-config"
      "workflow-authoring"
    ]
  ) (_: "user-invocable-only");

  ceilings = ./budget.json;

  # `<ceiling key> <subject> <bytes>` lines, as programs/agents' budget writes
  # them.
  #   flavors      - wrappers, each with its skillFarm
  #   agentSources - name -> a rendered agents/<name>.md
  sizes =
    { flavors, agentSources }:
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
          echo "listing ${flavor.name} $(listing ${flavor.skillFarm} | wc -c)" >>"$out"
        '') flavors}
        ${lib.concatStrings (
          lib.mapAttrsToList (name: source: ''
            echo "frontmatter ${name} $(frontmatter ${source} | wc -c)" >>"$out"
          '') agentSources
        )}
      '';
}
