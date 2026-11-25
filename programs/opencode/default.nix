# OpenCode, as one flavor: opencode-kategory, the base and local profiles in
# OpenCode's format, on DeepSeek, with OpenCode's own XDG dirs under
# ~/.opencode-kategory.
#
# codegen/ renders the profiles into one read-only config dir in the store,
# which the wrapper hands OpenCode as OPENCODE_CONFIG_DIR. So there is no
# link/ or load/: nothing in $HOME is written, and nothing there can go stale.
# No budget/ either: the agnostic ceilings in agents.budget hold, and OpenCode
# adds no size worth its own ceiling yet.
{
  pkgs,
  lib ? pkgs.lib,
  opencode,
  agents,
  ...
}:

let
  shellCheck = import ../shell-check { inherit pkgs; };
  skillMd = import ./codegen/skill-md.nix { inherit lib; };

  name = "opencode-kategory";

  profile = agents.fold [
    agents.profiles.base
    agents.profiles.local
  ];

  # The lead and each role tier, as provider/model. A project's opencode.json
  # or `--model` still wins over the lead's.
  models = {
    lead = "deepseek/deepseek-v4-pro";
    small = "deepseek/deepseek-flash";
    medium = "deepseek/deepseek-flash";
    large = "deepseek/deepseek-v4-pro";
  };

  # The XDG base dirs OpenCode gets under ~/.opencode-kategory.
  movedXdg = {
    XDG_CONFIG_HOME = "config";
    XDG_DATA_HOME = "data";
    XDG_STATE_HOME = "state";
    XDG_CACHE_HOME = "cache";
  };
  # The ones every shell gets back as the user's, each with the default an
  # unset one means (XDG Base Directory 0.8, section 3). Not XDG_STATE_HOME:
  # `state` keeps OpenCode's own run store under the moved one.
  userXdgDefaults = {
    XDG_CONFIG_HOME = ".config";
    XDG_DATA_HOME = ".local/share";
    XDG_CACHE_HOME = ".cache";
  };
  # Where the wrapper saves them, as one JSON object.
  userXdgVar = "OPENCODE_KATEGORY_USER_XDG";

  # The rules every agent, the lead too, ends with.
  shared = {
    # Where an agent may reach outside the project without asking, which a
    # headless `opencode run` would refuse: the flows' notes in /tmp and
    # ~/.10x, and the store, read-only, where this config dir and the paths
    # the instructions name live.
    external_directory = {
      "/tmp/**" = "allow";
      "~/.10x/**" = "allow";
      "${builtins.storeDir}/**" = "allow";
    };
    # A skill that keeps the model from invoking it runs only as its command.
    skill = lib.genAttrs (lib.filter (
      skill: skillMd.manualOnly "${agents.skills.all.${skill}}/SKILL.md"
    ) profile.skills) (_: "deny");
  };

  renderRoles = import ./codegen/role.nix {
    inherit pkgs lib shared;
    inherit (agents) renderRole;
    skillSources = agents.skills.all;
    models = removeAttrs models [ "lead" ];
  };
  roleSources = renderRoles agents.roles profile.instructions;

  # opencode.json without the lead's instructions, which live beside it: the
  # build below puts their store path first.
  config = pkgs.writeText "${name}-opencode.json" (
    builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = models.lead;
      # The deepest chain the flows spawn: lead -> engineer -> review-lead ->
      # reviewer. OpenCode's default, 1, keeps a subagent from spawning.
      subagent_depth = 3;
      # Nix pins the version, so the update check would only nag.
      autoupdate = false;
      # A project's own CLAUDE.md, which OPENCODE_DISABLE_CLAUDE_CODE would
      # skip. Found searching up to the worktree root, beside its AGENTS.md.
      instructions = [ "CLAUDE.md" ];
      permission = shared;
    }
  );

  # The config dir's files, folded so one path with two sources is an eval
  # error. The .gitignore spares OpenCode writing one into the store.
  links = pkgs.linkFarm "${name}-links" (
    agents.foldTargets (
      [
        {
          "AGENTS.md" = pkgs.concatText "${name}-AGENTS.md" (
            agents.renderLead profile.instructions ++ [ (import ./codegen/glossary.nix { inherit pkgs lib; }) ]
          );
          "plugin/kategory.js" = pkgs.replaceVars ./plugin/kategory.js { inherit userXdgVar; };
          ".gitignore" = pkgs.writeText "${name}-gitignore" "*\n";
        }
      ]
      ++ map (skill: { "skills/${skill}" = agents.skills.all.${skill}; }) profile.skills
      ++ lib.mapAttrsToList (role: source: { "agents/${role}.md" = source; }) roleSources
    )
  );

  # The config dir: the files relocated, every link resolved and every
  # ~/.claude path in their text pointed at this dir, then opencode.json.
  configDir = pkgs.runCommand "${name}-config" { nativeBuildInputs = [ pkgs.jq ]; } ''
    bash ${./relocate.sh} ${links} "$out"
    jq --arg lead "$out/AGENTS.md" '.instructions = [$lead] + .instructions' ${config} >"$out/opencode.json"
  '';
in
# The hooks a profile lists (the kernel's gate, the guards) do not run yet:
# OpenCode has no hook adapter, so they are left out, as docs/KATEGORY.md
# says. The rest a backend could drop silently fails here instead.
assert lib.assertMsg (
  profile.secretFiles == { }
) "${name}: secret files have no OpenCode wiring: ${toString (lib.attrNames profile.secretFiles)}";
assert lib.assertMsg (
  profile.mcp == { }
) "${name}: MCP servers have no OpenCode wiring: ${toString (lib.attrNames profile.mcp)}";
rec {
  kategory = shellCheck.writeShellApplication {
    inherit name;
    runtimeInputs = profile.runtime ++ [
      opencode
      pkgs.gh
      pkgs.git
      pkgs.jq
      pkgs.ripgrep
      pkgs.coreutils
      pkgs.python3
    ];
    runtimeEnv = {
      OPENCODE_CONFIG_DIR = configDir;
      # Neither ~/.claude nor ~/.agents: the harness brings its own skills and
      # instructions, and a project's CLAUDE.md comes back through
      # opencode.json's `instructions`.
      OPENCODE_DISABLE_CLAUDE_CODE = "1";
      OPENCODE_DISABLE_EXTERNAL_SKILLS = "1";
      # The flows spawn subagents in the background.
      OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true";
    };
    text = lib.concatLines [
      (lib.toShellVars {
        kategory_dir = ".${name}";
        moved_xdg = movedXdg;
        user_xdg_defaults = userXdgDefaults;
        user_xdg_var = userXdgVar;
      })
      (shellCheck.fragment ./launch.sh)
    ];
    passthru = {
      inherit configDir userXdgVar;
      # The XDG dirs every shell gets back as the user's, for the hook
      # adapter's own spawns.
      restoredXdg = lib.attrNames userXdgDefaults;
      # OpenCode's tools by vendor-free name, as JSON for the hook adapter.
      toolsFile = pkgs.writeText "opencode-tools.json" (builtins.toJSON (import ./codegen/tools.nix));
    };
  };

  # checks.opencode: the wrapper run offline against everything above.
  check = import ./check.nix {
    inherit pkgs lib kategory;
    roles = agents.roles;
    skills = profile.skills;
    # A role that may only read, rendered as the real ones are: none of them
    # is that narrow, as every one may run a shell.
    readOnlyRole =
      (renderRoles {
        read-only = agents.roles.reviewer // {
          name = "read-only";
          capabilities = [ "read" ];
        };
      } profile.instructions).read-only;
  };
}
