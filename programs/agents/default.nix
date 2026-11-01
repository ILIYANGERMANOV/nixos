{
  pkgs,
  lib ? pkgs.lib,
  externalSrcs ? { },
  ...
}:

let
  skills = import ./skills { inherit pkgs lib externalSrcs; };
  subagents = import ./subagents {
    inherit pkgs lib;
    inherit (skills) frontmatter;
    skillNames = skills.names;
  };
in
{
  # Agent-agnostic instructions, loaded at user scope by every agent.
  #
  # This layer only provides the content. It deliberately knows nothing about
  # where any agent expects to find it, because the agents disagree: Claude Code
  # hardcodes CLAUDE.md discovery and does not read AGENTS.md at user scope,
  # while Codex reads ~/.codex/AGENTS.md. Teaching this file either convention
  # would make the shared layer agent-shaped. Each agent program installs the
  # path its own way instead. See docs/adr/0002-agent-agnostic-configuration.md.
  instructions = ./AGENTS.md;

  # The skill catalog. Agent-agnostic because SKILL.md is a shared format, even
  # though Claude Code is currently its only consumer.
  inherit skills;

  # The subagent definitions. Each agent program installs them its own way.
  inherit subagents;

  # Every build-time check over shared agent config, wired into `nix flake check`
  # as `checks.agents`.
  check = pkgs.linkFarm "agents-check" [
    {
      name = "skills";
      path = skills.check;
    }
    {
      name = "subagents";
      path = subagents.check;
    }
  ];
}
