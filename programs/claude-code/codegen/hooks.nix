# A folded profile's hooks as Claude Code settings: one entry per event that has
# hooks, each running the adapter (hooks/adapter), which hands the event to the
# frontend's dispatcher. Claude never sees the hooks themselves, so their order
# and the threading of rewritten input are the frontend's, not Claude's
# parallel run. Appended to what the flavor sets, as withSecretFileGuard is,
# so the guards stay. Values only, no files.
{
  lib,
  # How a session can start, from the vocabulary. Claude's SessionStart sources
  # carry the same names.
  sources,
}:

let
  tools = import ./tools.nix;

  claudeTools = lib.concatMap (
    tool: tools.${tool} or (throw "claude-code: the hook tool ${tool} has no Claude tool")
  );
  # A hook with no tools sees every Claude tool, an MCP tool or Grep too, which
  # the adapter hands it as `other`: no matcher. Otherwise the tools' union.
  toolMatcher =
    hooks:
    if lib.any (hook: hook.tools == null) hooks then
      null
    else
      lib.concatStringsSep "|" (
        lib.unique (lib.sort lib.lessThan (lib.concatMap (hook: claudeTools hook.tools) hooks))
      );

  events = {
    sessionStart = {
      name = "SessionStart";
      matcher = _: lib.concatStringsSep "|" sources;
    };
    beforeTool = {
      name = "PreToolUse";
      matcher = toolMatcher;
    };
    afterTool = {
      name = "PostToolUse";
      matcher = toolMatcher;
    };
  };

  # `hook` is the adapter's settings entry, `hooks` event -> [hook], as
  # agents.fold leaves them.
  withHooks =
    hook: hooks: settings:
    let
      used = lib.filterAttrs (_: declared: declared != [ ]) hooks;
      entry =
        event: declared:
        let
          claude = events.${event} or (throw "claude-code: the hook event ${event} has no Claude event");
        in
        lib.nameValuePair claude.name (
          settings.hooks.${claude.name} or [ ]
          ++ [
            (
              lib.filterAttrs (_: value: value != null) {
                matcher = claude.matcher declared;
                hooks = [ hook ];
              }
            )
          ]
        );
    in
    if used == { } then
      settings
    else
      lib.recursiveUpdate settings { hooks = lib.mapAttrs' entry used; };
in
{
  inherit tools withHooks;
}
