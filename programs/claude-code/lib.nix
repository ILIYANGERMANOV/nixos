{
  pkgs,
  lib ? pkgs.lib,
  claude-code,
  mkSkillFarm,
  # programs/agents: profiles folded into one for this host, and the lead's
  # instruction render.
  fold,
  renderLead,
  ...
}:

let
  shellCheck = import ../shell-check { inherit pkgs; };

  mcp = import ./mcp.nix { inherit lib; };
  secretGuard = import ./secret-guard.nix { inherit pkgs; };

  # Binds the base settings authored in default.nix and returns the function that
  # turns an attrset of flavors into their wrapper derivations.
  #
  # Flavor options (the attr key is the binary name):
  #   profiles      - the programs/agents profiles it gets, folded in order:
  #                   its skills, instructions, MCP servers, runtime and
  #                   secret files, already narrowed to this host's secrets
  #   extraSettings - Nix attrset deep-merged onto baseSettings
  #   applySkills   - farm -> shell snippet that links ~/.claude/skills,
  #                   for a flavor mkApplySkills is not safe for
  #
  # A flavor puts its `runtime` on PATH and exports each of its secret files as
  # the decrypted file's PATH, guarded against being read from the session.
  mkFlavorBuilder =
    { baseSettings }:
    lib.mapAttrsToList (
      name:
      {
        profiles,
        extraSettings ? { },
        applySkills ? mkApplySkills,
      }:
      let
        profile = fold profiles;
      in
      mkFlavor {
        inherit name applySkills;
        servers = profile.mcp;
        files = profile.secretFiles;
        settings = withSecretFileGuard profile.secretFiles (lib.recursiveUpdate baseSettings extraSettings);
        inherit (profile) skills runtime;
        instructions = mkLeadInstructions name profile.instructions;
      }
    );

  # The lead's ~/.claude/CLAUDE.md, `<name>-instructions.md`.
  mkLeadInstructions =
    name: instructions: pkgs.concatText "${name}-instructions.md" (renderLead instructions);

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
  inherit mkFlavorBuilder mkLeadInstructions withSecretFileGuard;
}
