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

  # The wrapper's fragments in run order, as paths relative to this directory.
  # load.bats assembles its launch from the same file, so the order it tests is
  # this one: secrets first, so a missing one stops before ~/.claude changes.
  fragments = map (path: shellCheck.fragment (./. + "/${path}")) (
    lib.filter (line: line != "") (lib.splitString "\n" (builtins.readFile ./fragments))
  );

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
      passthru = {
        inherit (target) skillFarm instructions settingsFile;
      };
      text = lib.concatLines (
        [
          values
          ''
            apply_skills() {
              ${applySkills target.skillFarm}
            }
          ''
        ]
        ++ fragments
      );
    };

  applySkillsBin = shellCheck.writeShellApplication {
    name = "claude-apply-skills";
    runtimeInputs = [ pkgs.coreutils ];
    text = shellCheck.fragment ./apply-skills.sh;
  };

  # Shell snippet: rebuild ~/.claude/skills from this flavor's farm. It runs
  # inside apply_skills, after link.sh has set $claude_dir. See apply-skills.sh.
  mkApplySkills =
    skillFarm:
    "${lib.getExe applySkillsBin} \"$claude_dir\""
    + lib.optionalString (skillFarm != null) " ${skillFarm}";
in
{
  inherit mkWrapper mkApplySkills;
}
