# OpenCode, as two flavors on DeepSeek, each with OpenCode's own data, state
# and cache under ~/.<name>:
#
# - opencode-kategory: the base and local profiles, for a person at a terminal;
# - opencode-kategory-headless: the same plus the headless profile, for a run
#   with nobody there, such as a CI job. Its lead answers every question
#   itself, and OpenCode's question tool is off.
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

  # The lead and each role tier, as provider/model. The lead's is in
  # leadConfig, so a project's opencode.json or `--model` wins over it.
  models = {
    lead = "deepseek/deepseek-v4-pro";
    small = "deepseek/deepseek-flash";
    medium = "deepseek/deepseek-flash";
    large = "deepseek/deepseek-v4-pro";
  };

  # The XDG base dirs OpenCode gets under ~/.<name>.
  movedXdg = {
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

  # One flavor: `name`, the profiles it folds, and the permission rules it
  # adds to the shared ones. A rule both set is an eval error.
  mkFlavor =
    {
      name,
      profiles,
      permission ? { },
    }:
    let
      profile = agents.fold profiles;

      # OpenCode's XDG_CONFIG_HOME: an empty, read-only opencode/ in the store.
      # OpenCode runs `npm install @opencode-ai/plugin` in every config dir it
      # can write, its global one too: a few seconds online, about 70 offline,
      # on every first launch, which in a CI runner is every launch. It skips a
      # read-only one. The harness config is the store dir OPENCODE_CONFIG_DIR
      # names.
      configHome = pkgs.runCommand "${name}-config-home" { } ''
        mkdir -p "$out/opencode"
        cp ${gitignore} "$out/opencode/.gitignore"
      '';
      # OpenCode writes a .gitignore into each config dir that lacks one. It
      # skips only a denied write, so in a read-only store dir one ships
      # instead.
      gitignore = pkgs.writeText "${name}-gitignore" "*\n";

      # The rules every agent, the lead too, ends with.
      shared = {
        # Where an agent may reach outside the project without asking, which
        # a headless `opencode run` would refuse: the flows' notes in /tmp and
        # ~/.10x, and the store, read-only, where this config dir and the
        # paths the instructions name live.
        external_directory = {
          "/tmp/**" = "allow";
          "~/.10x/**" = "allow";
          "${builtins.storeDir}/**" = "allow";
        };
        # A skill that keeps the model from invoking it runs only as its
        # command.
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

      # The lead's model, as the OPENCODE_CONFIG file. OpenCode 1.19.5 merges
      # that file before a project's opencode.json and .opencode/ dirs, and
      # OPENCODE_CONFIG_DIR's opencode.json after them all, so only this one
      # yields to the project.
      leadConfig = pkgs.writeText "${name}-lead.json" (
        builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          model = models.lead;
        }
      );

      # opencode.json without the lead's instructions, which live beside it:
      # the build below puts their store path first.
      config = pkgs.writeText "${name}-opencode.json" (
        builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          # The deepest chain the flows spawn: lead -> engineer -> review-lead
          # -> reviewer. OpenCode's default, 1, keeps a subagent from spawning.
          subagent_depth = 3;
          # Nix pins the version, so the update check would only nag.
          autoupdate = false;
          # A project's own CLAUDE.md, which OPENCODE_DISABLE_CLAUDE_CODE would
          # skip. Found searching up to the worktree root, beside its AGENTS.md.
          instructions = [ "CLAUDE.md" ];
          permission = shared // permission;
        }
      );

      # The config dir's files, folded so one path with two sources is an
      # eval error.
      links = pkgs.linkFarm "${name}-links" (
        agents.foldTargets (
          [
            {
              "AGENTS.md" = pkgs.concatText "${name}-AGENTS.md" (
                agents.renderLead profile.instructions ++ [ (import ./codegen/glossary.nix { inherit pkgs lib; }) ]
              );
              "plugin/kategory.js" = pkgs.replaceVars ./plugin/kategory.js { inherit userXdgVar; };
              ".gitignore" = gitignore;
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
    assert lib.assertMsg (lib.intersectAttrs shared permission == { })
      "${name}: permission rules set twice: ${toString (lib.attrNames (lib.intersectAttrs shared permission))}";
    {
      inherit profile renderRoles;
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
          OPENCODE_CONFIG = leadConfig;
          # Neither ~/.claude nor ~/.agents: the harness brings its own skills
          # and instructions, and a project's CLAUDE.md comes back through
          # opencode.json's `instructions`.
          OPENCODE_DISABLE_CLAUDE_CODE = "1";
          OPENCODE_DISABLE_EXTERNAL_SKILLS = "1";
          # The flows spawn subagents in the background.
          OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true";
        };
        text = lib.concatLines [
          (lib.toShellVars {
            kategory_dir = ".${name}";
            config_home = configHome;
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
    };

  local = mkFlavor {
    name = "opencode-kategory";
    profiles = [
      agents.profiles.base
      agents.profiles.local
    ];
  };

  headless = mkFlavor {
    name = "opencode-kategory-headless";
    profiles = [
      agents.profiles.base
      agents.profiles.local
      agents.profiles.headless
    ];
    # Nobody is there to pick an answer. `run` already denies the tool in a
    # new session; this says so in the config, where the check sees it.
    permission.question = "deny";
  };
in
{
  inherit (local) kategory;
  kategoryHeadless = headless.kategory;

  # checks.opencode: the wrapper run offline against everything above.
  check = import ./check.nix {
    inherit pkgs lib;
    inherit (local) kategory;
    tiers = lib.mapAttrs (_: role: role.tier) agents.roles;
    inherit (local.profile) skills;
    # A role that may only read, rendered as the real ones are: none of them
    # is that narrow, as every one may run a shell.
    readOnlyRole =
      (local.renderRoles {
        read-only = agents.roles.reviewer // {
          name = "read-only";
          capabilities = [ "read" ];
        };
      } local.profile.instructions).read-only;
  };

  # checks.opencode-headless: the headless flavor runs a scripted model's
  # tool call to the end with nobody there. See check-headless.sh.
  checkHeadless =
    pkgs.runCommand "opencode-headless-check"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.python3
        ];
        env = {
          kategory = lib.getExe headless.kategory;
          scripted_model = "${./scripted-model.py}";
        };
      }
      ''
        bash ${./check-headless.sh}
        touch "$out"
      '';
}
