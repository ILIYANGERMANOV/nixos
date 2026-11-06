# The Claude Code configuration itself: the flavors, each the programs/agents
# profiles it gets plus Claude settings. codegen/ turns them into Claude's
# files, link/ writes them into ~/.claude and load/ starts Claude Code. MCP
# servers, the session runtime and secret files come with the profiles.
{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  agents,
  theme ? "auto",
  ...
}:

let
  statusline = import ./statusline/statusline.nix { inherit pkgs theme; };
  readGuard = import ./hooks/read-guard/read-guard.nix { inherit pkgs; };
  waitGuard = import ./hooks/wait-guard/wait-guard.nix { inherit pkgs; };
  contextGuard = import ./hooks/context-guard/context-guard.nix { inherit pkgs; };
  secretGuard = import ./hooks/secret-guard/secret-guard.nix { inherit pkgs; };
  linkSkills = import ../skills-link { inherit pkgs; };

  settings = import ./codegen/settings.nix { inherit lib statusline secretGuard; };
  codegen = import ./codegen/profile.nix {
    inherit pkgs lib;
    inherit (agents.skills) mkSkillFarm;
    inherit (agents) renderLead foldTargets;
    inherit (settings) withSecretFileGuard;
  };
  renderAgents = import ./codegen/role.nix {
    inherit pkgs lib;
    inherit (agents) renderRole;
  };
  link = import ./link/lib.nix { inherit pkgs lib claude-code; };
  budget = import ./budget {
    inherit pkgs lib;
    inherit (agents.skills) frontmatter;
  };
  inherit (budget) skillOverrides;

  # The profiles every flavor starts from, and the factory's. A profile's
  # instructions are installed the way Claude Code expects them: the lead's
  # render as user-scope memory at ~/.claude/CLAUDE.md, each role's in its
  # agents/<role>.md. Claude Code does not read AGENTS.md at user scope, so the
  # file is copied under the name it does read. A project's own CLAUDE.md still
  # stacks on top of this - user and project memory are separate entries, not
  # competing ones.
  inherit (agents.profiles) base web-ui pm local;
  baseProfiles = [ base ];
  factoryProfiles = [
    base
    agents.profiles.factory
  ];
  baseProfile = agents.fold baseProfiles;
  factoryProfile = agents.fold factoryProfiles;

  # Flavors as their wrappers; the attr key is the binary name.
  #   profiles      - the programs/agents profiles it gets, folded in order:
  #                   its skills, instructions, MCP servers, runtime and
  #                   secret files, already narrowed to this host's secrets
  #   extraSettings - Nix attrset deep-merged onto the base settings
  #   applySkills   - farm -> shell snippet that links ~/.claude/skills,
  #                   for a flavor mkApplySkills is not safe for
  mkClaudeFlavors = lib.mapAttrsToList (
    name:
    {
      profiles,
      extraSettings ? { },
      applySkills ? link.mkApplySkills,
    }:
    link.mkWrapper {
      inherit name applySkills;
      target = codegen.mkTarget {
        inherit name;
        profile = agents.fold profiles;
        settings = lib.recursiveUpdate settings.base extraSettings;
      };
    }
  );

  # The factory's sessions and subagents get its profile's instructions on top
  # of the shared ones, and no other host does.
  agentSources = renderAgents agents.roles baseProfile.instructions;
  factoryAgentSources = renderAgents agents.roles factoryProfile.instructions;

  activation = import ./link/activation.nix {
    inherit lib agentSources;
    inherit (agents) foldTargets;
    settingsFile = pkgs.writeText "claude-base-settings.json" (builtins.toJSON settings.base);
    instructionsFile = codegen.mkLeadInstructions "agent" baseProfile.instructions;
  };
  inherit (activation) toHomeFiles;

in
rec {
  inherit statusline;

  # When a changed file reaches a running Claude Code, by path. See
  # load/applies.nix.
  applies = import ./load/applies.nix { inherit lib; };

  # One entry per flavor; the attr name is the binary name. Only `profiles` is
  # required - `claude` is the base profile plus `local`, the delta every
  # non-factory flavor gets.
  packages = mkClaudeFlavors {
    claude.profiles = [
      base
      local
    ];

    claude-ts = {
      profiles = [
        base
        local
      ];
      extraSettings.enabledPlugins = {
        "typescript-lsp@claude-plugins-official" = true;
      };
    };

    claude-web-ui = {
      profiles = [
        base
        web-ui
        local
      ];
      extraSettings.enabledPlugins = {
        "typescript-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
      };
    };

    # claude-web-ui plus the product-work servers. Spelled out rather than
    # derived from claude-web-ui: flavors are flat by design, and one shared
    # `let` binding for a single pair would hide which binary gets what.
    claude-pm = {
      profiles = [
        base
        web-ui
        pm
        local
      ];
      extraSettings.enabledPlugins = {
        "typescript-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
      };
    };
  };

  # The software-factory server's flavor, kept out of `packages` so no other host
  # installs it. Its settings are only what a flavor may own: policy that must
  # not be editable by the agents themselves lives in the server's managed
  # settings (programs/software-factory).
  #
  # `unwrapped` is the binary the wrapper execs. The factory launches the wrapper
  # once under a lock to apply its files, then starts every Remote Control
  # server from this binary, so concurrent starts cannot race on ~/.claude.
  factory = {
    wrapper = builtins.head (mkClaudeFlavors {
      claude-factory = {
        profiles = factoryProfiles;
        # Other sessions keep running while this one starts, and read the
        # directory the stock rm -rf would empty under them.
        applySkills = farm: "${lib.getExe linkSkills} ${farm}";
        # Unattended agents dumped whole files with `cat` and Read, and
        # subagents blocked on foreground sleeps and polling loops despite
        # the instructions; the hooks make them read ranges and background
        # long commands instead, keep subagents off CI, and name the context
        # budget when an agent crosses it.
        extraSettings = {
          inherit skillOverrides;
          # The Claude Docs connector, used once ever and paid for on every call.
          # claude-code-remote is not a connector: Remote Control's bridge
          # delivers it, so add_repo and subscribe_pr_activity stay.
          disableClaudeAiConnectors = true;
          hooks.PreToolUse = [
            {
              matcher = "Bash";
              hooks = [
                readGuard.hook
                waitGuard.hook
              ];
            }
            {
              matcher = "Read";
              hooks = [ readGuard.hook ];
            }
          ];
          hooks.PostToolUse = [ { hooks = [ contextGuard.hook ]; } ];
          enabledPlugins = {
            "typescript-lsp@claude-plugins-official" = true;
          };
        };
      };
    });
    unwrapped = claude-code;
    agentFiles = toHomeFiles factoryAgentSources;
    # What the wrapper puts on PATH, for hosts whose sessions run `unwrapped`.
    inherit (factoryProfile) runtime;
  };

  # The hook guards as they deploy, for `python-tests` to run.
  guards = {
    read = readGuard.bin;
    wait = waitGuard.bin;
    secret = secretGuard.bin;
    context = contextGuard.bin;
  };

  # home.file entries for the subagents. Every flavor of a profile gets the same
  # ones, so unlike skills they need no per-flavor relink. The factory profile
  # installs `factory.agentFiles` instead.
  agentFiles = toHomeFiles agentSources;

  # checks.claude-config: this configuration against its size ceilings. See
  # config-check.nix.
  check =
    let
      flavors = packages ++ [ factory.wrapper ];
    in
    import ./config-check.nix {
      inherit pkgs lib;
      inherit (agents.skills) frontmatter;
      inherit (budget) compare;
      hiddenSkills = lib.attrNames skillOverrides;
      skillNames = agents.skills.names;
      baseProfileSkills = baseProfile.skills;
      inherit agentSources factoryAgentSources;
      roleSkills = lib.concatMap (role: role.skills) (lib.attrValues agents.roles);
      sizes = [
        # A role counts at its largest, the factory's render.
        (agents.budget.sizes {
          leads = lib.listToAttrs (map (flavor: lib.nameValuePair flavor.name flavor.instructions) flavors);
          roleInstructions = factoryProfile.instructions;
          repoInstructions = ../../CLAUDE.md;
        })
        (budget.sizes {
          inherit flavors;
          agentSources = factoryAgentSources;
        })
      ];
      ceilings = [
        agents.budget.ceilings
        budget.ceilings
      ];
    };

  inherit (activation) activationScript shellActivationScript;
}
