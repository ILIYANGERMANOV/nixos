# Claude Code's layout under $HOME: each part of a setup as a programs/agents
# target map, target path -> store path, for `foldTargets` to combine. A setup
# places only what that fold returns, so one target with two sources is an eval
# error. link/link.sh writes the same paths from shell.
{ lib }:

rec {
  settings = ".claude/settings.json";
  instructions = ".claude/CLAUDE.md";
  role = name: ".claude/agents/${name}.md";
  skill = name: ".claude/skills/${name}";

  # The settings and the lead's user-scope memory.
  lead = settingsFile: instructionsFile: {
    ${settings} = settingsFile;
    ${instructions} = instructionsFile;
  };

  # name -> the role's render, one map per role.
  roles = lib.mapAttrsToList (name: source: { ${role name} = source; });

  # The skills of a farm, one map per skill: each is a link into the farm.
  skills =
    farm:
    map (name: {
      ${skill name} = "${farm}/${name}";
    });
}
