{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  skills,
  theme ? "auto",
  ...
}:

let
  inherit
    (import ./lib.nix {
      inherit pkgs lib claude-code;
      inherit (skills) mkSkillFarm;
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

  mcpCatalog = {
    figma = mkMcpServer {
      command = "npx";
      args = [
        "-y"
        "figma-developer-mcp"
        "--stdio"
      ];
      token = {
        path = "/run/secrets/figma-token";
        envVar = "FIGMA_API_KEY";
      };
    };
  };

  # Skills every flavor gets. Names must be installed by programs/skills —
  # requesting an unknown one aborts evaluation. Flavor-specific additions go in
  # that flavor's `extraSkills`.
  baseSkills = [
    "grill-with-docs"
    "grilling"
    "domain-modeling"
    "grill-me"
    "setup-matt-pocock-skills"
  ];

  claude = mkClaudeFlavor {
    name = "claude";
    inherit baseSettings mcpCatalog baseSkills;
  };

  claude-ts = mkClaudeFlavor {
    name = "claude-ts";
    inherit baseSettings mcpCatalog baseSkills;
    extraSettings.enabledPlugins = {
      "typescript-lsp@claude-plugins-official" = true;
    };
  };

  claude-web-ui = mkClaudeFlavor {
    name = "claude-web-ui";
    inherit baseSettings mcpCatalog baseSkills;
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

  # Writes base settings on every rebuild so the file exists before the first
  # `claude` invocation. Each wrapper then overwrites it at launch time.
  activationScript = ''
    mkdir -p "$HOME/.claude"
    cp ${baseSettingsFile} "$HOME/.claude/settings.json"
  '';
}
