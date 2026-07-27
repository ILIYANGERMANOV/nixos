{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  ...
}:

let

  # Constructs a typed MCP server entry for the catalog.
  # token = { path, envVar } is optional; omit for servers without secrets.
  mkMcpServer =
    {
      command,
      args,
      token ? null,
    }:
    { inherit command args; } // lib.optionalAttrs (token != null) { inherit token; };

  # Builds a named Claude wrapper binary that owns both ~/.claude/settings.json
  # and the mcpServers key in ~/.claude.json for its lifetime. Every invocation
  # resets both so switching between flavors is always clean.
  #
  # Security model: secrets are read from sops-nix at invocation time, exported
  # as process env vars, and inherited by Claude Code via exec. ~/.claude.json
  # stores only ${VAR} references which Claude Code resolves via expandVars.
  #
  # Options:
  #   name          — binary name (required)
  #   extraSettings — Nix attrset deep-merged onto baseSettings
  #   mcpServers    — list of server names from mcpCatalog to activate
  #
  # To add a new flavor:
  #   myFlavor = makeFlavor {
  #     name          = "claude-my-flavor";
  #     extraSettings = { effortLevel = "high"; };
  #     mcpServers    = [ "figma" ];
  #   };
  # Then add it to `packages` below.
  mkClaudeFlavor =
    {
      name,
      baseSettings,
      mcpCatalog,
      extraSettings ? { },
      mcpServers ? [ ],
    }:
    let
      servers = lib.filterAttrs (n: _: builtins.elem n mcpServers) mcpCatalog;
      serversWithTokens = lib.filterAttrs (_: s: s ? token) servers;

      # Deep-merge extra settings onto base so nested keys (e.g. enabledPlugins) combine.
      flavorSettings = lib.recursiveUpdate baseSettings extraSettings;
      settingsFile = pkgs.writeText "${name}-settings.json" (builtins.toJSON flavorSettings);

      # Nix store file with the MCP structure. Env fields hold ${VAR} references,
      # not secret values — safe to bake into the store.
      mcpStaticFile = pkgs.writeText "${name}-mcp-static.json" (builtins.toJSON (mkMcpStructure servers));
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.jq ]; # always needed for ~/.claude.json management
      text = ''
        mkdir -p "$HOME/.claude"
        cp "${settingsFile}" "$HOME/.claude/settings.json"
        ${mkApplyMcp { inherit mcpStaticFile serversWithTokens; }}
        exec ${claude-code}/bin/claude "$@"
      '';
    };

  # Shell snippet: validate each secret file exists, then export it as an env var.
  # Secrets are NOT written to any file. Claude Code's expandVars (confirmed enabled
  # for user scope in source) resolves ${VAR} references in ~/.claude.json from the
  # process environment inherited via exec.
  mkReadTokens =
    serversWithTokens:
    lib.concatStrings (
      lib.mapAttrsToList (_: s: ''
        if [ ! -f "${s.token.path}" ]; then
          echo "Error: secret not found at ${s.token.path}" >&2
          echo "Ensure sops-nix has decrypted secrets and darwin-rebuild has run." >&2
          exit 1
        fi
        ${s.token.envVar}=$(cat "${s.token.path}")
        export ${s.token.envVar}
      '') serversWithTokens
    );

  # Builds the static MCP structure for ~/.claude.json.
  # Env values are ${VAR} REFERENCES — the literal strings "${FIGMA_API_KEY}" etc.
  # Claude Code's expandVars resolves them from the process environment at startup.
  # The actual secret values never touch ~/.claude.json.
  #
  # "$" + "{" + name + "}" produces the literal string "${NAME}" in Nix without
  # triggering Nix's own string interpolation syntax.
  mkMcpStructure =
    servers:
    lib.mapAttrs (_: s: {
      type = "stdio";
      inherit (s) command args;
      env = lib.optionalAttrs (s ? token) {
        ${s.token.envVar} = "$" + "{" + s.token.envVar + "}";
      };
    }) servers;

  # Shell snippet: atomically update ~/.claude.json with this flavor's MCP servers.
  # mcpStaticFile is a Nix store path with the static JSON (env var references only).
  # Replaces mcpServers entirely so switching flavors is always clean.
  mkApplyMcp =
    { mcpStaticFile, serversWithTokens }:
    let
      hasTokens = serversWithTokens != { };
    in
    ''
      ${lib.optionalString hasTokens (mkReadTokens serversWithTokens)}
      [ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"
      _claude_tmp=$(mktemp "$HOME/.claude.json.XXXXXX")
      trap 'rm -f "$_claude_tmp"' EXIT
      jq --slurpfile mcp "${mcpStaticFile}" ".mcpServers = \$mcp[0]" \
        "$HOME/.claude.json" > "$_claude_tmp"
      mv "$_claude_tmp" "$HOME/.claude.json"
    '';
in
{
  inherit mkMcpServer mkClaudeFlavor;
}
