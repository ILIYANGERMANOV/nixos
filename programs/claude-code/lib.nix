{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  mkSkillFarm,
  ...
}:

let

  # Constructs a typed MCP server entry for the catalog.
  #
  # token = { secret, envVar } is optional; omit for servers without secrets.
  # `secret` is a NAME from the myConfig.secrets registry, not a path: the
  # caller resolves it against the set of secrets the host actually provides,
  # and drops the entry entirely when there is no match.
  mkMcpServer =
    {
      command,
      args,
      token ? null,
    }:
    { inherit command args; } // lib.optionalAttrs (token != null) { inherit token; };

  # Builds a named Claude wrapper binary that owns ~/.claude/settings.json,
  # ~/.claude/CLAUDE.md, the mcpServers key in ~/.claude.json, and the
  # ~/.claude/skills directory for its lifetime. Every invocation resets all four
  # so switching between flavors is always clean.
  #
  # Security model: secrets are read from sops-nix at invocation time, exported
  # as process env vars, and inherited by Claude Code via exec. ~/.claude.json
  # stores only ${VAR} references which Claude Code resolves via expandVars.
  #
  # Options:
  #   name              - binary name (required)
  #   extraSettings     - Nix attrset deep-merged onto baseSettings
  #   mcpCatalog        - servers AVAILABLE on this host, tokens resolved to paths
  #   knownMcpServers   - every name the catalog defines, available or not
  #   mcpServers        - list of server names from knownMcpServers to activate
  #   baseSkills        - skill names every flavor gets (passed in from default.nix)
  #   extraSkills       - skill names this flavor adds on top
  #   baseInstructions  - the agent-agnostic AGENTS.md (passed in from default.nix)
  #   extraInstructions - markdown files this flavor appends to them
  #
  # To add a new flavor:
  #   myFlavor = makeFlavor {
  #     name          = "claude-my-flavor";
  #     extraSettings = { effortLevel = "high"; };
  #     mcpServers    = [ "figma" ];
  #     extraSkills   = [ "tdd" ];
  #   };
  # Then add it to `packages` below.
  mkClaudeFlavor =
    {
      name,
      baseSettings,
      mcpCatalog,
      knownMcpServers ? lib.attrNames mcpCatalog,
      baseInstructions,
      extraSettings ? { },
      mcpServers ? [ ],
      baseSkills ? [ ],
      extraSkills ? [ ],
      extraInstructions ? [ ],
    }:
    let
      # Validated against every DEFINED name, then read from the AVAILABLE ones.
      # A typo aborts evaluation, the way an unknown skill name already does; a
      # server this host has no secret for is simply absent, which is the point.
      unknownMcp = lib.subtractLists knownMcpServers mcpServers;
      servers =
        if unknownMcp != [ ] then
          throw ''
            claude flavor "${name}": unknown MCP server(s): ${lib.concatStringsSep ", " unknownMcp}.
            Defined in mcpCatalog: ${lib.concatStringsSep ", " knownMcpServers}.
          ''
        else
          lib.filterAttrs (n: _: builtins.elem n mcpServers) mcpCatalog;
      serversWithTokens = lib.filterAttrs (_: s: s ? token) servers;

      # Deep-merge extra settings onto base so nested keys (e.g. enabledPlugins) combine.
      flavorSettings = lib.recursiveUpdate baseSettings extraSettings;
      settingsFile = pkgs.writeText "${name}-settings.json" (builtins.toJSON flavorSettings);

      # Nix store file with the MCP structure. Env fields hold ${VAR} references,
      # not secret values — safe to bake into the store.
      mcpStaticFile = pkgs.writeText "${name}-mcp-static.json" (builtins.toJSON (mkMcpStructure servers));

      skillNames = lib.unique (baseSkills ++ extraSkills);
      skillFarm = if skillNames == [ ] then null else mkSkillFarm "${name}-skills" skillNames;

      # A flavor with nothing to add installs the shared file as-is, so the common
      # case costs no build and ~/.claude/CLAUDE.md is byte-identical to
      # programs/agents/AGENTS.md.
      instructionsFile =
        if extraInstructions == [ ] then
          baseInstructions
        else
          pkgs.concatText "${name}-instructions.md" ([ baseInstructions ] ++ extraInstructions);
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.jq ]; # always needed for ~/.claude.json management
      text = ''
        mkdir -p "$HOME/.claude"
        ${mkApplySkills skillFarm}
        ${mkApplyInstructions instructionsFile}
        install -m 600 "${settingsFile}" "$HOME/.claude/settings.json"
        ${mkApplyMcp { inherit mcpStaticFile serversWithTokens; }}
        exec ${claude-code}/bin/claude "$@"
      '';
    };

  # Shell snippet: rebuild ~/.claude/skills from this flavor's farm.
  #
  # The directory is replaced wholesale rather than reconciled, so switching
  # flavors can never leave a stale skill behind. The cost is that anything
  # hand-placed in ~/.claude/skills is discarded on the next launch — prototype
  # new skills in a project's .claude/skills instead, then commit them to
  # programs/agents/skills/custom.
  #
  # Entries are per-skill symlinks into the store rather than one symlink for the
  # whole directory: per-entry symlinks are what Claude Code documents support for.
  mkApplySkills =
    skillFarm:
    ''
      rm -rf "$HOME/.claude/skills"
    ''
    + lib.optionalString (skillFarm != null) ''
      mkdir -p "$HOME/.claude/skills"
      ln -s ${skillFarm}/* "$HOME/.claude/skills/"
    '';

  # Shell snippet: rewrite ~/.claude/CLAUDE.md from the store on every launch.
  #
  # User-scope memory is Nix-owned, on the same terms as ~/.claude/skills: the
  # file is replaced wholesale, so anything written into it by hand or by the `#`
  # memory shortcut is discarded on the next launch. Machine-local rules belong
  # in a project's own CLAUDE.md, which still stacks on top of this one.
  #
  # `install -m 600`, not `cp`: store paths are mode 444 and Claude Code never
  # rewrites CLAUDE.md, so a plain `cp` would succeed once and then fail with
  # EACCES on every later launch - fatal under `set -o errexit`.
  mkApplyInstructions = instructionsFile: ''
    install -m 600 "${instructionsFile}" "$HOME/.claude/CLAUDE.md"
  '';

  # Shell snippet: validate each secret file exists, then export it as an env var.
  # Secrets are NOT written to any file. Claude Code's expandVars (confirmed enabled
  # for user scope in source) resolves ${VAR} references in ~/.claude.json from the
  # process environment inherited via exec.
  #
  # A missing file is fatal, not a reason to drop the server: this server is only
  # here because the host DECLARED its secret, so a missing file means the
  # promise is broken (no age key, or a rebuild that never ran) rather than that
  # the feature is off. Hosts that genuinely lack the secret never get this far.
  mkReadTokens =
    serversWithTokens:
    lib.concatStrings (
      lib.mapAttrsToList (n: s: ''
        if [ ! -f "${s.token.path}" ]; then
          echo "Error: MCP server '${n}' needs ${s.token.path}, which does not exist." >&2
          echo "$(hostname -s) declares this secret via myConfig.secrets, so it should be there." >&2
          echo "Check the age key (just darwin-install-age-key) and re-run darwin-rebuild switch." >&2
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
