{
  pkgs,
  lib ? pkgs.lib,
  externalSrcs ? { },
  # The /qa skill's runtime package, put on PATH by the base profile.
  qa,
  # name -> decrypted-file path, for the secrets THIS host provides. Paths only,
  # never values. A server or secret file whose secret is absent is dropped.
  secrets ? { },
  ...
}:

let
  instructionsLib = import ./lib/instructions.nix { inherit pkgs lib; };
  inherit (instructionsLib) mkFragment mkInstructions;
  mcpLib = import ./lib/mcp.nix { inherit pkgs lib; };
  mcpCatalog = import ./mcp { inherit (mcpLib) mkLocal mkRemote; };
  profileLib = import ./lib/profile.nix {
    inherit pkgs lib;
    instructions = instructionsLib;
    skillNames = skills.names;
    selectServers = mcpLib.selectServers mcpCatalog;
    serverNames = lib.attrNames mcpCatalog;
  };
  targets = import ./lib/targets.nix { inherit pkgs lib; };
  hooks = import ./hooks {
    inherit pkgs lib;
    packages = { inherit state; };
  };
  dedupLib = import ./lib/passes/dedup.nix {
    inherit pkgs lib;
    instructions = instructionsLib;
  };
  modesLib = import ./lib/passes/modes.nix {
    inherit pkgs lib;
    roots = [
      ./skills/custom
      ./roles
      ./instructions
    ];
    exempt = [
      ./instructions/topics/quality.md
      ./skills/custom/self-improve
    ];
    allowed = [
      {
        file = ./skills/custom/engineer/SKILL.md;
        labels = [ "POC:" ];
      }
      {
        file = ./skills/custom/pragmatic-review/references/first-pass.md;
        labels = [
          "**Balanced row.**"
          "**POC row.**"
        ];
      }
    ];
  };
  budget = import ./lib/passes/budget.nix {
    inherit pkgs lib roles;
    inherit (instructionsLib) renderRole;
    skills = skills.all;
  };

  topic =
    file:
    mkFragment {
      layer = "topic";
      inherit file;
    };
  topics = {
    trivial = topic ./instructions/topics/trivial.md;
    quality = topic ./instructions/topics/quality.md;
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
  # `ctx`: the review diff in a cached folder, on PATH in every session.
  ctx = import ./ctx { inherit pkgs; };
  # `state`: the engineer flow's event log and advice, on PATH beside `ctx`.
  state = import ./state {
    inherit pkgs;
    agentHook = hooks.module;
  };
  profiles = import ./profiles {
    inherit (profileLib) mkProfile;
    inherit
      lib
      mkFragment
      mkInstructions
      topics
      qa
      ctx
      state
      ;
  };

  # A folded profile narrowed to what this host can run: servers whose secrets it
  # lacks dropped, secret names resolved to their paths. Its hook files become
  # each event's hooks in the order they run.
  forHost =
    profile:
    profile
    // {
      mcp = mcpLib.availableServers secrets profile.mcp;
      secretFiles = mcpLib.provided secrets profile.secretFiles;
      hooks = hooks.eval profile.hooks;
    };
in
{
  # The profiles, by name: the vendor-free part of each setup. A harness lists
  # the ones a setup gets and folds them with `fold`.
  #
  # Their instructions are only the content, rendered with `renderLead` and
  # `renderRole`. This layer deliberately knows nothing about where any agent
  # expects to find them, because the agents disagree on the file name and its
  # directory. Teaching this file one convention would make the shared layer
  # agent-shaped. Each agent program installs the path its own way instead. See
  # docs/adr/0002-agent-agnostic-configuration.md.
  inherit profiles;
  inherit (instructionsLib) renderLead renderRole;

  # Profiles appended in order, refused if the result still holds a duplicate,
  # then narrowed to this host's secrets: `mcp` and `secretFiles` hold paths,
  # `hooks` each event's hooks in order.
  fold = selected: forHost (dedupLib.dedup (profileLib.fold selected));

  # The skill catalog. Agent-agnostic because SKILL.md is a shared format.
  inherit skills;

  # The `ctx` and `state` commands, the ones the base profile's runtime puts on PATH.
  inherit ctx state;

  # The hooks a folded profile carries, for a backend: the `vocabulary` it maps,
  # the `manifest` its adapter hands the dispatcher, and that dispatcher, the
  # Python `module` agent_hook. See hooks/default.nix.
  hooks = { inherit (hooks) vocabulary manifest module; };

  # The subagent roles, by name, as records. Each agent program renders them its
  # own way.
  inherit roles;

  # What one setup places under $HOME, target path -> store path, combined
  # only through this fold: two sources for one target throw. See
  # lib/targets.nix.
  foldTargets = targets.fold;

  # The size budget every agent program shares: `sizes` to measure and their
  # `ceilings`. See lib/passes/budget.nix.
  inherit budget;

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
      # Packages are left out: deepSeq on a derivation walks all of nixpkgs.
      path = builtins.deepSeq (lib.mapAttrs (
        _: profile: removeAttrs profile [ "runtime" ]
      ) profiles) profileLib.check;
    }
    {
      name = "dedup";
      path = dedupLib.check;
    }
    {
      name = "modes";
      path = modesLib.check;
    }
    {
      name = "mcp";
      path = mcpLib.check;
    }
    {
      name = "targets";
      path = targets.check;
    }
    {
      name = "hooks";
      path = hooks.check;
    }
    {
      name = "roles";
      path = builtins.deepSeq roles roleLib.check;
    }
  ];
}
