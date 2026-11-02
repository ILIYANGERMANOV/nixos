{
  pkgs,
  lib ? pkgs.lib,
  externalSrcs ? { },
  ...
}:

let
  instructionsLib = import ./lib/instructions.nix { inherit pkgs lib; };
  inherit (instructionsLib) mkFragment mkInstructions;
  profileLib = import ./lib/profile.nix {
    inherit pkgs lib;
    instructions = instructionsLib;
    skillNames = skills.names;
  };
  dedupLib = import ./lib/passes/dedup.nix {
    inherit pkgs lib;
    instructions = instructionsLib;
  };

  topics.trivial = mkFragment {
    layer = "topic";
    file = ./instructions/topics/trivial.md;
  };

  skills = import ./skills { inherit pkgs lib externalSrcs; };
  roleLib = import ./lib/role.nix {
    inherit pkgs lib;
    skillNames = skills.names;
  };
  roles = import ./roles {
    inherit lib mkFragment topics;
    inherit (roleLib) mkRole discover;
  };
  profiles = import ./profiles {
    inherit (profileLib) mkProfile;
    inherit
      lib
      mkFragment
      mkInstructions
      topics
      ;
  };
in
{
  # The profiles, by name: the vendor-free part of each setup. A harness lists
  # the ones a setup gets and folds them with `fold`.
  #
  # Their instructions are only the content, rendered with `renderLead` and
  # `renderRole`. This layer deliberately knows nothing about where any agent
  # expects to find them, because the agents disagree: Claude Code hardcodes
  # CLAUDE.md discovery and does not read AGENTS.md at user scope, while Codex
  # reads ~/.codex/AGENTS.md. Teaching this file either convention would make
  # the shared layer agent-shaped. Each agent program installs the path its own
  # way instead. See docs/adr/0002-agent-agnostic-configuration.md.
  inherit profiles;
  inherit (instructionsLib) renderLead renderRole;

  # Profiles appended in order, refused if the result still holds a duplicate.
  fold = selected: dedupLib.dedup (profileLib.fold selected);

  # The skill catalog. Agent-agnostic because SKILL.md is a shared format, even
  # though Claude Code is currently its only consumer.
  inherit skills;

  # The subagent roles, by name, as records. Each agent program renders them its
  # own way.
  inherit roles;

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
      name = "profiles";
      path = builtins.deepSeq profiles profileLib.check;
    }
    {
      name = "dedup";
      path = dedupLib.check;
    }
    {
      name = "roles";
      path = builtins.deepSeq roles roleLib.check;
    }
  ];
}
