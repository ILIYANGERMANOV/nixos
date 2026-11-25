# Renders the agent-agnostic subagent records as the agents/<name>.md files
# OpenCode reads from its config dir. Everything OpenCode-specific about a role
# is here.
#
# Only fields OpenCode 1.19.5 documents: it moves an unknown frontmatter field
# into the agent's `options`, where nothing reads it. Not written:
#   effort     - DeepSeek's reasoning variants are not Claude's effort levels,
#                so a role runs at its model's default.
#   cache      - Claude's prompt cache lifetime; OpenCode has no such setting.
#   operations - prose only, as in Claude Code.
{
  pkgs,
  lib,
  renderRole,
  # name -> the catalog skill's store path.
  skillSources,
  # tier -> provider/model.
  models,
  # The rules every agent ends with: where it may go outside the project, and
  # which skills only their command may run. See default.nix.
  shared,
}:

let
  tools = import ./tools.nix;
  skillMd = import ./skill-md.nix { inherit lib; };

  # OpenCode allows every tool by default, where Claude Code's `tools:` is an
  # allowlist. So a role opens with a deny of everything, and its capabilities
  # lift it key by key; a dropped capability can only narrow the role. OpenCode
  # takes the last rule that matches, in the order written, and toJSON writes
  # keys sorted, so `*` (and `*` within `skill`) comes first.
  permission =
    capabilities:
    {
      "*" = "deny";
    }
    // lib.genAttrs (lib.concatMap (capability: tools.${capability}.permission) capabilities) (
      _: "allow"
    )
    // {
      inherit (shared) external_directory;
    }
    // lib.optionalAttrs (lib.elem "skill" capabilities) {
      skill = {
        "*" = "allow";
      }
      // shared.skill;
    };

  # Claude Code injects a role's `skills:` into its context at start; OpenCode
  # has no such field, so the skill's body follows the role's instructions. Its
  # `${CLAUDE_SKILL_DIR}` becomes the frontend's spelling of that skill's
  # folder, which relocate.sh then points at the config dir.
  preload =
    skill:
    pkgs.writeText "${skill}-preload.md" (
      builtins.replaceStrings [ "\${CLAUDE_SKILL_DIR}" ] [ "~/.claude/skills/${skill}" ] (
        skillMd.body "${skillSources.${skill}}/SKILL.md"
      )
    );

  render =
    instructions: agent:
    let
      header = [
        "description: ${builtins.toJSON agent.description}"
        "mode: subagent"
      ]
      ++ lib.optional (agent.tier != null) "model: ${models.${agent.tier}}"
      ++ [ "permission: ${builtins.toJSON (permission agent.capabilities)}" ];
    in
    pkgs.concatText "${agent.name}.md" (
      [
        (pkgs.writeText "${agent.name}-header" ''
          ---
          ${lib.concatStringsSep "\n" header}
          ---

        '')
      ]
      ++ renderRole instructions agent.instructions
      ++ map preload agent.skills
    );
in
# The roles' files, by name, each given `instructions`' forAll on top of its own.
agents: instructions: lib.mapAttrs (_: render instructions) agents
