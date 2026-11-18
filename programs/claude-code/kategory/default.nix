# claude-kategory: the factory's harness for anyone with Nix, in its own
# config dir. A pure half, the factory profile as Claude Code's files under
# ~/.claude-kategory in the store, and an effect half, the wrapper that links
# them in and starts Claude Code. Nothing of the user's ~/.claude or
# ~/.claude.json is read or written.
{
  pkgs,
  lib,
  claude-code,
  mkTarget,
  foldTargets,
  # The folded factory profile and its settings, as claude-factory gets them.
  profile,
  settings,
  # name -> the role's rendered agents/<name>.md.
  roleSources,
  # Permission deny rules that hold off the factory too: no push to main, no
  # force push, no reading credentials or keys.
  deny,
}:

let
  shellCheck = import ../../shell-check { inherit pkgs; };
  home = import ../codegen/home.nix { inherit lib; };

  name = "claude-kategory";
  configDir = ".claude-kategory";

  # What the user may choose and Claude Code saves to their settings.json.
  # `--settings` outranks that file, so any of these left in would undo the
  # user's choice on every launch.
  userKeys = [
    "model"
    "effortLevel"
    "modelSettings"
    "theme"
    "enabledPlugins"
  ];

  target = mkTarget {
    inherit name profile;
    settings = lib.recursiveUpdate (removeAttrs settings userKeys) { permissions = { inherit deny; }; };
  };

  # The files in the layout of codegen/home.nix, folded so one path with two
  # sources is an eval error, then relocated: every link resolved and every
  # ~/.claude path in their text pointed at ~/.claude-kategory.
  files = pkgs.runCommand "${name}-home" { } ''
    bash ${./relocate.sh} ${
      pkgs.linkFarm "${name}-links" (
        foldTargets (
          [ (home.lead target.settingsFile target.instructions) ]
          ++ home.skills target.skillFarm profile.skills
          ++ home.roles roleSources
        )
      )
    } "$out" ${configDir}
  '';
in
shellCheck.writeShellApplication {
  inherit name;
  runtimeInputs = [ pkgs.coreutils ];
  text = lib.concatLines [
    (lib.toShellVars {
      claude_bin = "${claude-code}/bin/claude";
      config_dir = configDir;
      store_dir = builtins.storeDir;
      skills_dir = "${files}/${home.skillsDir}";
      agents_dir = "${files}/${home.agentsDir}";
      instructions_file = "${files}/${home.instructions}";
      settings_file = "${files}/${home.settings}";
      runtime_path = lib.makeBinPath (
        target.runtime
        ++ [
          claude-code
          pkgs.gh
          pkgs.git
          pkgs.jq
          pkgs.ripgrep
          pkgs.coreutils
          pkgs.python3
        ]
      );
      secret_files = target.secretFiles;
    })
    (shellCheck.fragment ./link.sh)
    (shellCheck.fragment ../load/load.sh)
  ];
}
