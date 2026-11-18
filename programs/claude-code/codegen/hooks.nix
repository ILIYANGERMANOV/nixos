# A folded profile's hooks as Claude Code settings: one entry per Claude event
# an event that has hooks covers, each running the adapter (hooks/adapter),
# which hands the event to the frontend's dispatcher. Claude never sees the hooks themselves, so their order
# and the threading of rewritten input are the frontend's, not Claude's
# parallel run. Appended to what the flavor sets, as withSecretFileGuard is,
# so a flavor's own hooks stay. Values only, no files.
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

  # Each vendor-free event as the Claude events it covers: one, but for an
  # agent stopping, which Claude splits into a subagent's and the lead's.
  events = {
    sessionStart = [
      {
        name = "SessionStart";
        matcher = _: lib.concatStringsSep "|" sources;
      }
    ];
    beforeTool = [
      {
        name = "PreToolUse";
        matcher = toolMatcher;
      }
    ];
    afterTool = [
      {
        name = "PostToolUse";
        matcher = toolMatcher;
      }
    ];
    # None takes a matcher the hooks need: every subagent starts and stops,
    # every typed command expands, and Stop takes no matcher at all.
    agentStart = [ (unmatched "SubagentStart") ];
    promptExpansion = [ (unmatched "UserPromptExpansion") ];
    agentStop = [
      (unmatched "SubagentStop")
      (unmatched "Stop")
    ];
  };
  unmatched = name: {
    inherit name;
    matcher = _: null;
  };

  # `hook` is the adapter's settings entry, `hooks` event -> [hook], as
  # agents.fold leaves them.
  withHooks =
    hook: hooks: settings:
    let
      used = lib.filterAttrs (_: declared: declared != [ ]) hooks;
      entries =
        event: declared:
        map (
          claude:
          lib.nameValuePair claude.name (
            settings.hooks.${claude.name} or [ ]
            ++ [
              (lib.filterAttrs (_: value: value != null) {
                matcher = claude.matcher declared;
                hooks = [ hook ];
              })
            ]
          )
        ) (events.${event} or (throw "claude-code: the hook event ${event} has no Claude event"));
    in
    if used == { } then
      settings
    else
      lib.recursiveUpdate settings {
        hooks = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList entries used));
      };
in
{
  inherit tools withHooks;
}
