{ pkgs, lib ? pkgs.lib, theme ? "auto", ... }:

let
  inherit (import ./lib.nix { inherit pkgs lib; }) mkClaudeFlavor mkMcpServer;
  statusline = import ./statusline.nix { inherit pkgs theme; };

  baseSettings = {
    statusLine = {
      type = "command";
      command = "${statusline}/bin/claude-statusline";
    };
    autoMemoryEnabled = false;
    effortLevel = "medium";
    theme = "auto";
    enabledPlugins = {
      "typescript-lsp@claude-plugins-official" = true;
    };
  };

  mcpCatalog = {
    figma = mkMcpServer {
      command = "npx";
      args = [ "-y" "figma-developer-mcp" "--stdio" ];
      token = { path = "/run/secrets/figma-token"; envVar = "FIGMA_API_KEY"; };
    };
  };

  claude-base = mkClaudeFlavor {
    name = "claude";
    inherit baseSettings mcpCatalog;
  };

  claude-web-ui = mkClaudeFlavor {
    name = "claude-web-ui";
    inherit baseSettings mcpCatalog;
    extraSettings.enabledPlugins = {
      "frontend-design@claude-plugins-official" = true;
    };
    mcpServers = [ "figma" ];
  };

  baseSettingsFile = pkgs.writeText "claude-base-settings.json"
    (builtins.toJSON baseSettings);
in
{
  packages = [ claude-base claude-web-ui ];

  # Writes base settings on every rebuild so the file exists before the first
  # `claude` invocation. Each wrapper then overwrites it at launch time.
  activationScript = ''
    mkdir -p "$HOME/.claude"
    cp ${baseSettingsFile} "$HOME/.claude/settings.json"
  '';
}
