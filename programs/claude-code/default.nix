{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  theme ? "auto",
  ...
}:

let
  inherit (import ./lib.nix { inherit pkgs lib claude-code; }) mkClaudeFlavor mkMcpServer;
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

  claude = mkClaudeFlavor {
    name = "claude";
    inherit baseSettings mcpCatalog;
  };

  claude-ts = mkClaudeFlavor {
    name = "claude-ts";
    inherit baseSettings mcpCatalog;
    extraSettings.enabledPlugins = {
      "typescript-lsp@claude-plugins-official" = true;
    };
  };

  claude-web-ui = mkClaudeFlavor {
    name = "claude-web-ui";
    inherit baseSettings mcpCatalog;
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
