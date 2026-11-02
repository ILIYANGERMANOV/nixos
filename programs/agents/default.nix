{
  pkgs,
  lib ? pkgs.lib,
  externalSrcs ? { },
  ...
}:

let
  instructionsLib = import ./lib/instructions.nix { inherit pkgs lib; };
  inherit (instructionsLib) mkFragment mkInstructions;

  topics.trivial = mkFragment {
    layer = "topic";
    file = ./instructions/topics/trivial.md;
  };

  skills = import ./skills { inherit pkgs lib externalSrcs; };
  subagents = import ./subagents {
    inherit
      pkgs
      lib
      mkFragment
      topics
      ;
    skillNames = skills.names;
  };
in
{
  # Agent-agnostic instructions, loaded at user scope by every agent: a value of
  # lib/instructions.nix, rendered with `renderLead` and `renderRole`.
  #
  # This layer only provides the content. It deliberately knows nothing about
  # where any agent expects to find it, because the agents disagree: Claude Code
  # hardcodes CLAUDE.md discovery and does not read AGENTS.md at user scope,
  # while Codex reads ~/.codex/AGENTS.md. Teaching this file either convention
  # would make the shared layer agent-shaped. Each agent program installs the
  # path its own way instead. See docs/adr/0002-agent-agnostic-configuration.md.
  #
  # agent.md is what every agent gets, subagent roles included; lead.md is the
  # lead's own role, and the lead also gets the trivial topic.
  instructions = mkInstructions {
    forAll = [
      (mkFragment {
        layer = "agent";
        file = ./instructions/agent.md;
      })
    ];
    forLead = [
      (mkFragment {
        layer = "role";
        file = ./instructions/lead.md;
      })
      topics.trivial
    ];
  };
  inherit (instructionsLib)
    append
    empty
    renderLead
    renderRole
    ;

  # The profiles' instructions, appended to `instructions` on the hosts that run
  # them. The factory's agent.md reaches every role there, lead.md only the lead.
  profiles.factory.instructions = mkInstructions {
    forAll = [
      (mkFragment {
        layer = "context";
        file = ./profiles/factory/agent.md;
      })
    ];
    forLead = [
      (mkFragment {
        layer = "context";
        file = ./profiles/factory/lead.md;
      })
    ];
  };

  # The skill catalog. Agent-agnostic because SKILL.md is a shared format, even
  # though Claude Code is currently its only consumer.
  inherit skills;

  # The subagent roles, as records. Each agent program renders them its own way.
  inherit subagents;

  # Every build-time check over shared agent config, wired into `nix flake check`
  # as `checks.agents`.
  check = pkgs.linkFarm "agents-check" [
    {
      name = "skills";
      path = skills.check;
    }
    {
      name = "instructions";
      path = instructionsLib.check;
    }
    {
      name = "subagents";
      path = subagents.check;
    }
  ];
}
