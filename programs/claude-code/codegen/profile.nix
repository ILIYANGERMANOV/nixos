# A folded programs/agents profile as the files Claude Code reads: settings.json,
# the lead's CLAUDE.md, the skill farm for ~/.claude/skills and the mcpServers of
# ~/.claude.json, plus what the wrapper puts in the session's environment. The
# wrapper (link/lib.nix) writes them; nothing here touches $HOME.
{
  pkgs,
  lib,
  mkSkillFarm,
  renderLead,
  withSecretFileGuard,
}:

let
  mcp = import ./mcp.nix { inherit lib; };

  # The lead's ~/.claude/CLAUDE.md, `<name>-instructions.md`.
  mkLeadInstructions =
    name: instructions: pkgs.concatText "${name}-instructions.md" (renderLead instructions);

  # A flavor's target. Its secret files go out as paths, and the settings guard
  # them against being read from the session.
  mkTarget =
    {
      name,
      profile,
      settings,
    }:
    {
      settingsFile = pkgs.writeText "${name}-settings.json" (
        builtins.toJSON (withSecretFileGuard profile.secretFiles settings)
      );
      instructions = mkLeadInstructions name profile.instructions;
      skillFarm = if profile.skills == [ ] then null else mkSkillFarm "${name}-skills" profile.skills;

      # Env fields hold ${VAR} references, not secret values: safe to bake into
      # the store.
      mcpStaticFile = pkgs.writeText "${name}-mcp-static.json" (
        builtins.toJSON (mcp.mkMcpStructure profile.mcp)
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
          ) profile.mcp
        )
      );

      inherit (profile) runtime secretFiles;
    };
in
{
  inherit mkLeadInstructions mkTarget;
}
