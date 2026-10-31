# The Claude Code configuration itself: settings, skills, instructions, the MCP
# catalog and the flavors built from them. Everything mechanical - merging,
# resolving secrets, writing the wrappers - lives in lib.nix, so adding a server
# or a flavor is a change to this file alone.
{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  agents,
  theme ? "auto",
  secrets ? { },
  ...
}:

let
  inherit
    (import ./lib.nix {
      inherit
        pkgs
        lib
        claude-code
        secrets
        ;
      inherit (agents.skills) mkSkillFarm;
    })
    mkFlavorBuilder
    mkStdioServer
    mkHttpServer
    ;
  statusline = import ./statusline.nix { inherit pkgs theme; };
  readGuard = import ./read-guard.nix { inherit pkgs; };
  waitGuard = import ./wait-guard.nix { inherit pkgs; };
  contextGuard = import ./context-guard.nix { inherit pkgs; };
  playwright = import ../playwright { inherit pkgs; };
  linkFarm = import ../farm-link { inherit pkgs; };

  model = "opus";
  effortLevel = "medium";

  baseSettings = {
    statusLine = {
      type = "command";
      command = "${statusline}/bin/claude-statusline";
    };
    autoMemoryEnabled = false;
    # In user settings the top-level key only reaches a fixed list of older
    # models. Opus 5.5 and later read modelSettings, which also takes an alias.
    inherit effortLevel model;
    modelSettings.${model} = { inherit effortLevel; };
    theme = "auto";
  };

  # Local servers name the SECRETS they need, never a path. Which hosts provide
  # them is decided by modules/secrets.nix; a server whose secret this host does
  # not declare is dropped before any flavor sees it, and a flavor naming a
  # server that is not in this catalog at all aborts evaluation.
  #
  # Remote servers name no secrets and are therefore available everywhere: they
  # authenticate out-of-band, once per machine, via `/mcp` inside Claude Code.
  # A host that should not reach one simply does not run a flavor that lists it.
  mcpCatalog = {
    figma = mkStdioServer {
      command = "npx";
      args = [
        "-y"
        "figma-developer-mcp"
        "--stdio"
      ];
      env.FIGMA_API_KEY = "figma-token";
    };

    # Read-write. Linear also serves /mcp/readonly, but the point of claude-pm
    # is filing and updating issues, not only reading them.
    linear = mkHttpServer { url = "https://mcp.linear.app/mcp"; };

    # Coda's docs product, renamed after the Superhuman acquisition. The old
    # coda.io/apis/mcp endpoint still answers but is documented as deprecated.
    superhuman-docs = mkHttpServer { url = "https://docs.superhuman.com/apis/mcp"; };
  };

  # On PATH in every session, whatever the project: /qa's `qa-node` (Playwright,
  # Chromium, viem and the qa-wallet helper) and `qa-mp4` (ffmpeg).
  runtime = [ playwright.qa ];

  # Secrets a session gets as a file PATH in an env var, never as a value, for
  # a program that reads the file itself. Like the MCP catalog, an entry whose
  # secret this host does not declare is dropped: the variable is then absent.
  # The session is blocked from reading the file (see withSecretFileGuard).
  secretFiles = {
    # /qa's wallet key, read by qa-wallet in Node.
    QA_EVM_KEY_FILE = "qa-sepolia-key";
  };

  # The agent-agnostic instructions, installed the way Claude Code expects them:
  # as user-scope memory at ~/.claude/CLAUDE.md. Claude Code does not read
  # AGENTS.md at user scope, so the file is copied under the name it does read.
  # A project's own CLAUDE.md still stacks on top of this - user and project
  # memory are separate entries, not competing ones.
  baseInstructions = agents.instructions;

  # Skills every flavor gets. Names must be installed by programs/agents/skills -
  # requesting an unknown one aborts evaluation. Flavor-specific additions go in
  # that flavor's `extraSkills`.
  baseSkills = [
    "address-pr-feedback"
    "engineer"
    "engineering"
    "explain"
    "final-review"
    "give-feedback"
    "grill-with-docs"
    "grilling"
    "domain-modeling"
    "grill-me"
    "pr-description"
    "pragmatic-review"
    "qa"
    "refactor"
    "researcher"
    "setup-matt-pocock-skills"
    "skeptic"
    "ui-coding"
  ];

  mkClaudeFlavors = mkFlavorBuilder {
    inherit
      baseSettings
      baseSkills
      baseInstructions
      mcpCatalog
      runtime
      secretFiles
      ;
    agentFarm = agents.subagents.farm;
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
      "pdf"
      "pptx"
      "skill-creator"
      "xlsx"
    ]
    ++ [
      "claude-api"
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

  # What one kind of agent reads for its work, on top of what every agent
  # carries, for the size budget: files, by path.
  budgetLoads =
    let
      inherit (agents.skills) all;
      review = "${all.pragmatic-review}/references";
    in
    {
      review-agent = [
        "${review}/first-pass.md"
        "${review}/bar.md"
        "${review}/blockers.md"
      ];
      implementer = [
        "${all.engineer}/references/implementer.md"
        "${all.engineering}/SKILL.md"
      ];
      researcher = [
        agents.subagents.all.researcher
        "${all.researcher}/SKILL.md"
      ];
      repo-instructions = [ ../../CLAUDE.md ];
    };

  baseSettingsFile = pkgs.writeText "claude-base-settings.json" (builtins.toJSON baseSettings);
in
rec {
  # One entry per flavor; the attr name is the binary name. Everything is
  # optional - `claude` is the base configuration with nothing added.
  packages = mkClaudeFlavors {
    claude = { };

    claude-ts.extraSettings.enabledPlugins = {
      "typescript-lsp@claude-plugins-official" = true;
    };

    claude-web-ui = {
      mcpServers = [ "figma" ];
      extraSettings.enabledPlugins = {
        "typescript-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
      };
    };

    # claude-web-ui plus the product-work servers. Spelled out rather than
    # derived from claude-web-ui: flavors are flat by design, and one shared
    # `let` binding for a single pair would hide which binary gets what.
    claude-pm = {
      mcpServers = [
        "figma"
        "linear"
        "superhuman-docs"
      ];
      # self-improve measures this Mac's own sessions; its analyzer needs the
      # python3 that modules/home/terminal.nix installs.
      extraSkills = [ "self-improve" ];
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
        extraInstructions = [ ./factory-instructions.md ];
        # Other sessions keep running while this one starts, and read the
        # directory the stock rm -rf would empty under them.
        applyLinks = dir: farm: "${lib.getExe linkFarm} ${dir} ${farm}";
        # self-improve measures this box's own transcripts; android describes
        # the toolchain only the factory has; 10x-engineer relies on its session
        # tools and unattended rules.
        extraSkills = [
          "10x-engineer"
          "self-improve"
          "android"
        ];
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
  };

  # checks.claude-config: this configuration against its size ceilings. See
  # config-check.nix.
  check = import ./config-check.nix {
    inherit pkgs lib;
    inherit (agents.skills) frontmatter;
    hiddenSkills = lib.attrNames skillOverrides;
    skillNames = agents.skills.names;
    flavors = packages ++ [ factory.wrapper ];
    loads = budgetLoads;
    ceilings = ./budget.json;
  };

  # Writes the base settings and instructions on every rebuild so both files
  # exist before the first `claude` invocation. Each wrapper then overwrites
  # them at launch time.
  #
  # `install -m 600`, not `cp`: store paths are mode 444, so copying one over a
  # previous copy of itself fails with EACCES. `install` sets the mode on the
  # destination it writes, which makes the operation repeatable.
  activationScript = ''
    mkdir -p "$HOME/.claude"
    install -m 600 ${baseSettingsFile} "$HOME/.claude/settings.json"
    install -m 600 ${baseInstructions} "$HOME/.claude/CLAUDE.md"
  '';
}
