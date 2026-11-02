# What a rebuild writes into ~/.claude, before any wrapper runs.
{
  lib,
  # The base flavor's settings.json and CLAUDE.md.
  settingsFile,
  instructionsFile,
  # name -> the role's rendered agents/<name>.md.
  agentSources,
}:

rec {
  # Writes the base settings and instructions on every rebuild so both files
  # exist before the first `claude` invocation. Each wrapper then overwrites
  # them at launch time.
  #
  # `install -m 600`, not `cp`: store paths are mode 444, so copying one over a
  # previous copy of itself fails with EACCES. `install` sets the mode on the
  # destination it writes, which makes the operation repeatable.
  activationScript = ''
    mkdir -p "$HOME/.claude"
    install -m 600 ${settingsFile} "$HOME/.claude/settings.json"
    install -m 600 ${instructionsFile} "$HOME/.claude/CLAUDE.md"
  '';

  # activationScript for a dev shell, where no Home Manager places `agentFiles`:
  # the install shells run on machines that have none yet.
  shellActivationScript = activationScript + ''
    mkdir -p "$HOME/.claude/agents"
    ${lib.concatStrings (
      lib.mapAttrsToList (name: source: ''
        install -m 600 ${source} "$HOME/.claude/agents/${name}.md"
      '') agentSources
    )}
  '';

  # home.file entries for the subagents, by role name.
  #
  # `force`: a dev shell may have installed a plain copy here, see
  # shellActivationScript. Home Manager would keep backing it up, and abort once
  # a backup already exists.
  toHomeFiles = lib.mapAttrs' (
    name: source:
    lib.nameValuePair ".claude/agents/${name}.md" {
      inherit source;
      force = true;
    }
  );
}
