# The guards as a hook module (hooks/default.nix), listed by the base profile.
# `guards` is the package beside it; `secretFiles` the host's secret files, env
# var -> decrypted-file path, as `fold` narrowed them. A host with none gets no
# secret guard. The first deny stops the rest, so a shell call runs secret,
# read, then wait: a command naming a secret is told that first.
{
  lib,
  guards,
  secretFiles,
  ...
}:
{
  hooks = {
    read-guard = {
      on = "beforeTool";
      tools = [
        "shell"
        "read"
      ];
      command = [ (lib.getExe guards.read) ];
      order = 2;
    };
    wait-guard = {
      on = "beforeTool";
      tools = [ "shell" ];
      command = [ (lib.getExe guards.wait) ];
      order = 3;
    };
    # Every tool, those with no vendor-free name too: any call adds context.
    context-guard = {
      on = "afterTool";
      command = [ (lib.getExe guards.context) ];
    };
  }
  // lib.optionalAttrs (secretFiles != { }) {
    secret-guard = {
      on = "beforeTool";
      tools = [ "shell" ];
      command = [
        (lib.getExe guards.secret)
        (builtins.toJSON {
          paths = lib.attrValues secretFiles;
          vars = lib.attrNames secretFiles;
        })
      ];
      order = 1;
    };
  };
}
