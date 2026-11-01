# Renders the agent-agnostic subagent records as the `<name>.md` files Claude Code
# reads from ~/.claude/agents. Everything Claude-specific about a role is here.
#
# Only documented fields, and every one is checked in config-check.nix: Claude
# Code ignores what it does not know.
{ pkgs, lib }:

let
  # Named, because a role must never inherit every tool: that brings each MCP
  # server. Tools deferred behind ToolSearch, such as WebFetch, are dropped by a
  # `tools` list unless listed. Never deny ToolSearch: that inlines them all.
  tools = {
    read = [ "Read" ];
    edit = [
      "Edit"
      "Write"
    ];
    shell = [ "Bash" ];
    web = [
      "WebFetch"
      "WebSearch"
    ];
    delegate = [ "Agent" ];
  };

  models = {
    small = "haiku";
    medium = "sonnet";
    large = "opus";
  };

  render =
    extraInstructions: agent:
    let
      header = [
        "name: ${agent.name}"
        "description: ${builtins.toJSON agent.description}"
        "tools: ${
          lib.concatStringsSep ", " (lib.concatMap (capability: tools.${capability}) agent.capabilities)
        }"
        "omitClaudeMd: true"
      ]
      ++ lib.optional (agent.effort != null) "effort: ${agent.effort}"
      ++ lib.optional (agent.tier != null) "model: ${models.${agent.tier}}"
      ++ lib.optionals (agent.skills != [ ]) ([ "skills:" ] ++ map (skill: "  - ${skill}") agent.skills);
    in
    pkgs.concatText "${agent.name}.md" (
      [
        (pkgs.writeText "${agent.name}-header" ''
          ---
          ${lib.concatStringsSep "\n" header}
          ---

        '')
      ]
      ++ agent.instructions
      ++ extraInstructions
    );
in
# The roles' files, by name, each with `extraInstructions` appended.
agents: extraInstructions: lib.mapAttrs (_: render extraInstructions) agents
