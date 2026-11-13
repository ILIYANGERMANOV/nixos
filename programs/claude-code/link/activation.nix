# What a rebuild writes into ~/.claude, before any wrapper runs.
{
  lib,
  foldTargets,
  # The base flavor's settings.json and CLAUDE.md.
  settingsFile,
  instructionsFile,
  # name -> the role's rendered agents/<name>.md.
  agentSources,
}:

let
  home = import ../codegen/home.nix { inherit lib; };

  # Everything a rebuild places, read back from this one fold, so no script
  # installs a target with two sources.
  files = foldTargets ([ (home.lead settingsFile instructionsFile) ] ++ home.roles agentSources);
  # Where Claude Code reads its config, as link.sh computes it.
  dir = "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}";
  install = path: ''
    install -m 600 ${files.${path}} "${dir}/${lib.removePrefix ".claude/" path}"
  '';
in
rec {
  # Writes the base settings and instructions on every rebuild so both files
  # exist before the first `claude` invocation. Each wrapper then overwrites
  # them at launch time.
  #
  # `install -m 600`, not `cp`: store paths are mode 444, so copying one over a
  # previous copy of itself fails with EACCES. `install` sets the mode on the
  # destination it writes, which makes the operation repeatable.
  activationScript = ''
    mkdir -p "${dir}"
  ''
  + install home.settings
  + install home.instructions;

  # activationScript for a dev shell, where no Home Manager places `agentFiles`:
  # the install shells run on machines that have none yet.
  shellActivationScript =
    activationScript
    + ''
      mkdir -p "${dir}/agents"
    ''
    + lib.concatMapStrings (name: install (home.role name)) (lib.attrNames agentSources);

  # home.file entries for the subagents, by target path.
  #
  # `force`: a dev shell may have installed a plain copy here, see
  # shellActivationScript. Home Manager would keep backing it up, and abort once
  # a backup already exists.
  toHomeFiles =
    sources:
    lib.mapAttrs (_: source: {
      inherit source;
      force = true;
    }) (foldTargets (home.roles sources));
}
