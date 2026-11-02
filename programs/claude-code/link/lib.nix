# The flavor wrapper: a named Claude binary that links its target (see
# codegen/profile.nix) into ~/.claude, then loads Claude Code with it. It owns
# ~/.claude/settings.json, ~/.claude/CLAUDE.md, the mcpServers key in
# ~/.claude.json and the ~/.claude/skills directory for its lifetime. Every
# invocation resets all four, so switching between flavors is always clean.
#
# Security model: secrets are read from sops-nix at invocation time, exported
# as process env vars, and inherited by Claude Code via exec. ~/.claude.json
# stores only ${VAR} references which Claude Code resolves via expandVars. A
# secret file goes out as its path, never its value.
{
  pkgs,
  lib,
  claude-code,
}:

let
  shellCheck = import ../../shell-check { inherit pkgs; };

  # applySkills: farm -> shell snippet that links ~/.claude/skills.
  mkWrapper =
    {
      name,
      target,
      applySkills,
    }:
    let
      values = lib.toShellVars {
        claude_bin = "${claude-code}/bin/claude";
        instructions_file = "${target.instructions}";
        mcp_secrets = target.mcpSecrets;
        mcp_static_file = "${target.mcpStaticFile}";
        runtime_path = lib.makeBinPath target.runtime;
        secret_files = target.secretFiles;
        settings_file = "${target.settingsFile}";
      };
    in
    shellCheck.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.jq ]; # always needed for ~/.claude.json management
      passthru = { inherit (target) skillFarm instructions; };
      text = lib.concatLines [
        values
        ''
          apply_skills() {
            ${applySkills target.skillFarm}
          }
        ''
        (shellCheck.fragment ../load/secrets.sh)
        (shellCheck.fragment ./link.sh)
        (shellCheck.fragment ../load/load.sh)
      ];
    };

  # Shell snippet: rebuild ~/.claude/skills from this flavor's farm.
  #
  # The directory is replaced wholesale rather than reconciled, so switching
  # flavors can never leave a stale skill behind. The cost is that anything
  # hand-placed in ~/.claude/skills is discarded on the next launch - prototype
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
  inherit mkWrapper mkApplySkills;
}
