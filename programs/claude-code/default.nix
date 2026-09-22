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
      inherit pkgs lib claude-code;
      inherit (agents.skills) mkSkillFarm;
    })
    mkClaudeFlavor
    mkMcpServer
    ;
  statusline = import ./statusline.nix { inherit pkgs theme; };

  baseSettings = {
    statusLine = {
      type = "command";
      command = "${statusline}/bin/claude-statusline";
    };
    autoMemoryEnabled = false;
    effortLevel = "high";
    model = "opus";
    theme = "auto";
  };

  # Catalog entries name the SECRET they need, never a path. Which hosts
  # provide that secret is decided by modules/secrets.nix; this file only ever
  # sees the name-to-path attrset it was handed, so programs/ stays
  # host-agnostic.
  mcpCatalog = {
    figma = mkMcpServer {
      command = "npx";
      args = [
        "-y"
        "figma-developer-mcp"
        "--stdio"
      ];
      token = {
        secret = "figma-token";
        envVar = "FIGMA_API_KEY";
      };
    };
  };

  # A server whose secret this host does not provide is dropped here, so a
  # flavor listing it gets nothing at all rather than a server fed a placeholder
  # token. Survivors have their secret name resolved to the real path.
  #
  # Flavors validate their `mcpServers` against the FULL catalog and read from
  # this one, so a typo still aborts evaluation while a deliberately
  # unavailable server stays silent.
  availableMcp =
    let
      resolve =
        s:
        if s ? token then
          s
          // {
            token = {
              inherit (s.token) envVar;
              path = secrets.${s.token.secret};
            };
          }
        else
          s;
    in
    lib.mapAttrs (_: resolve) (
      lib.filterAttrs (_: s: !(s ? token) || secrets ? ${s.token.secret}) mcpCatalog
    );

  knownMcpServers = lib.attrNames mcpCatalog;

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
    "engineering"
    "grill-with-docs"
    "grilling"
    "domain-modeling"
    "grill-me"
    "pragmatic-review"
    "setup-matt-pocock-skills"
    "skeptic"
  ];

  claude = mkClaudeFlavor {
    name = "claude";
    inherit
      baseSettings
      baseSkills
      baseInstructions
      knownMcpServers
      ;
    mcpCatalog = availableMcp;
  };

  claude-ts = mkClaudeFlavor {
    name = "claude-ts";
    inherit
      baseSettings
      baseSkills
      baseInstructions
      knownMcpServers
      ;
    mcpCatalog = availableMcp;
    extraSettings.enabledPlugins = {
      "typescript-lsp@claude-plugins-official" = true;
    };
  };

  claude-web-ui = mkClaudeFlavor {
    name = "claude-web-ui";
    inherit
      baseSettings
      baseSkills
      baseInstructions
      knownMcpServers
      ;
    mcpCatalog = availableMcp;
    extraSkills = [ "ui-coding" ];
    extraSettings.enabledPlugins = {
      "typescript-lsp@claude-plugins-official" = true;
      "frontend-design@claude-plugins-official" = true;
    };
    mcpServers = [ "figma" ];
  };

  baseSettingsFile = pkgs.writeText "claude-base-settings.json" (builtins.toJSON baseSettings);
in
{
  packages = [
    claude
    claude-ts
    claude-web-ui
  ];

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
