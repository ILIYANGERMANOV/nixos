# Claude Code's settings.json: what every flavor starts from, and the guard a
# flavor's secret files add on top of its own settings. Values only, no files.
{
  lib,
  # The status line program, `claude-statusline` in its bin.
  statusline,
  secretGuard,
}:

let
  model = "opus";
  effortLevel = "medium";

  base = {
    statusLine = {
      type = "command";
      command = "${statusline}/bin/claude-statusline";
    };
    autoMemoryEnabled = false;
    # In user settings the top-level key only reaches a fixed list of older
    # models. Opus 5.5 and later read modelSettings, which also takes an alias.
    inherit effortLevel model;
    modelSettings.${model} = { inherit effortLevel; };
    theme = "auto";
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
in
{
  inherit base withSecretFileGuard;
}
