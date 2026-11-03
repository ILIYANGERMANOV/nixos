# A folded programs/agents profile as the files Claude Code reads: settings.json,
# the lead's CLAUDE.md, the skill farm for ~/.claude/skills and the mcpServers of
# ~/.claude.json, plus what the wrapper puts in the session's environment. The
# wrapper (link/lib.nix) writes them; nothing here touches $HOME.
{
  pkgs,
  lib,
  mkSkillFarm,
  renderLead,
  foldTargets,
  withSecretFileGuard,
}:

let
  mcp = import ./mcp.nix { inherit lib; };
  home = import ./home.nix { inherit lib; };

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
    let
      settingsFile = pkgs.writeText "${name}-settings.json" (
        builtins.toJSON (withSecretFileGuard profile.secretFiles settings)
      );
      skillFarm = if profile.skills == [ ] then null else mkSkillFarm "${name}-skills" profile.skills;

      # Everything the link step places. The files are read back from this one
      # fold, so no wrapper builds past a target with two sources.
      files = foldTargets (
        [ (home.lead settingsFile (mkLeadInstructions name profile.instructions)) ]
        ++ lib.optionals (skillFarm != null) (home.skills skillFarm profile.skills)
      );
    in
    {
      settingsFile = files.${home.settings};
      instructions = files.${home.instructions};
      inherit skillFarm;

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
