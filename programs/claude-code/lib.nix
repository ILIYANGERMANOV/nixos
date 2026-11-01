{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  mkSkillFarm,
  # name -> decrypted-file path, for the secrets THIS host provides.
  secrets ? { },
  ...
}:

let
  shellCheck = import ../shell-check { inherit pkgs; };

  mcp = import ./mcp.nix { inherit lib secrets; };
  secretGuard = import ./secret-guard.nix { inherit pkgs; };

  # Binds one Claude Code configuration - the settings, skills, instructions and
  # MCP catalog authored in default.nix - and returns the function that turns an
  # attrset of flavors into their wrapper derivations.
  #
  # Everything derived from that configuration is computed once, here, rather
  # than per flavor: the catalog is filtered against this host's secrets exactly
  # once, and the list of defined names never has to be passed alongside it.
  #
  # Flavor options, all optional (the attr key is the binary name):
  #   extraSettings     - Nix attrset deep-merged onto baseSettings
  #   mcpServers        - names from the catalog to activate for this flavor
  #   extraSkills       - skill names this flavor adds to baseSkills
  #   extraInstructions - markdown files appended to baseInstructions
  #   applySkills       - farm -> shell snippet that links ~/.claude/skills,
  #                       for a flavor mkApplySkills is not safe for
  #
  # Every flavor also gets `runtime` on PATH and, of `secretFiles` (env var ->
  # secret name), each one this host declares exported as its decrypted
  # file's PATH, guarded against being read from the session.
  mkFlavorBuilder =
    {
      baseSettings,
      baseSkills,
      baseInstructions,
      mcpCatalog,
      runtime,
      secretFiles,
    }:
    let
      known = lib.attrNames mcpCatalog;
      available = mcp.availableServers mcpCatalog;
      # env var -> decrypted-file path, for the secret files this host provides.
      files = lib.mapAttrs (_: secret: secrets.${secret}) (
        lib.filterAttrs (_: secret: secrets ? ${secret}) secretFiles
      );
      guardSecretFiles = withSecretFileGuard files;
    in
    lib.mapAttrsToList (
      name:
      {
        extraSettings ? { },
        mcpServers ? [ ],
        extraSkills ? [ ],
        extraInstructions ? [ ],
        applySkills ? mkApplySkills,
      }:
      let
        servers = mcp.selectServers {
          flavor = name;
          inherit known available;
          requested = mcpServers;
        };
      in
      mkFlavor {
        inherit
          name
          servers
          runtime
          files
          applySkills
          ;
        settings = guardSecretFiles (lib.recursiveUpdate baseSettings extraSettings);
        skills = lib.unique (baseSkills ++ extraSkills);
        instructions =
          if extraInstructions == [ ] then
            # A flavor with nothing to add installs the shared file as-is, so the
            # common case costs no build and ~/.claude/CLAUDE.md is
            # byte-identical to programs/agents/AGENTS.md.
            baseInstructions
          else
            pkgs.concatText "${name}-instructions.md" ([ baseInstructions ] ++ extraInstructions);
      }
    );

  # Builds a named Claude wrapper binary that owns ~/.claude/settings.json,
  # ~/.claude/CLAUDE.md, the mcpServers key in ~/.claude.json, and the
  # ~/.claude/skills directory for its lifetime. Every invocation resets all four
  # so switching between flavors is always clean.
  #
  # Security model: secrets are read from sops-nix at invocation time, exported
  # as process env vars, and inherited by Claude Code via exec. ~/.claude.json
  # stores only ${VAR} references which Claude Code resolves via expandVars.
  mkFlavor =
    {
      name,
      settings,
      skills,
      instructions,
      servers,
      runtime,
      files,
      applySkills,
    }:
    let
      settingsFile = pkgs.writeText "${name}-settings.json" (builtins.toJSON settings);
      skillFarm = if skills == [ ] then null else mkSkillFarm "${name}-skills" skills;

      # Nix store file with the MCP structure. Env fields hold ${VAR} references,
      # not secret values — safe to bake into the store.
      mcpStaticFile = pkgs.writeText "${name}-mcp-static.json" (
        builtins.toJSON (mcp.mkMcpStructure servers)
      );

      # server, variable, path of every secret, flat: bash has no list of lists.
      mcpSecrets = lib.concatLists (
        lib.concatLists (
          lib.mapAttrsToList (
            server:
            { env, ... }:
            lib.mapAttrsToList (var: path: [
              server
              var
              path
            ]) env
          ) servers
        )
      );

      values = lib.toShellVars {
        claude_bin = "${claude-code}/bin/claude";
        instructions_file = "${instructions}";
        mcp_secrets = mcpSecrets;
        mcp_static_file = "${mcpStaticFile}";
        runtime_path = lib.makeBinPath runtime;
        secret_files = files;
        settings_file = "${settingsFile}";
      };
    in
    shellCheck.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.jq ]; # always needed for ~/.claude.json management
      passthru = { inherit skillFarm instructions; };
      text = ''
        ${values}
        apply_skills() {
          ${applySkills skillFarm}
        }
        ${shellCheck.fragment ./wrapper.sh}
      '';
    };

  # Settings that keep a session from accidentally reading the secret files it
  # is handed as paths: Read deny rules over their directory, and a Bash hook
  # blocking the obvious shell routes to them (secret-guard.py). This is
  # protection against accidental reads, not a security boundary: the program
  # that needs the secret reads the variable itself, and so can any script the
  # session runs. Appended to whatever the flavor sets, so a flavor's own deny
  # rules and Bash hooks stay. No files, no change.
  withSecretFileGuard =
    files: settings:
    if files == { } then
      settings
    else
      lib.recursiveUpdate settings {
        permissions.deny = settings.permissions.deny or [ ] ++ secretDirDenyRules files;
        hooks.PreToolUse = settings.hooks.PreToolUse or [ ] ++ [
          {
            matcher = "Bash";
            hooks = [ (secretGuard.hookFor files) ];
          }
        ];
      };

  # Read deny rules for every directory holding a secret file, and for the
  # `<dir>.d` that sops-nix points it at (`/run/secrets -> /run/secrets.d/<n>`),
  # so neither the symlinked nor the resolved path is readable. macOS resolves
  # `/run` itself to `/private/var/run`, so that spelling is denied too. `//`
  # makes a rule's path absolute rather than project-relative.
  secretDirDenyRules =
    files:
    lib.concatMap (
      dir:
      lib.concatMap
        (root: [
          "Read(/${root}${dir}/**)"
          "Read(/${root}${dir}.d/**)"
        ])
        [
          ""
          "/private/var"
        ]
    ) (lib.unique (map dirOf (lib.attrValues files)));

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
in
{
  inherit (mcp) mkStdioServer mkHttpServer;
  inherit mkFlavorBuilder withSecretFileGuard;
}
