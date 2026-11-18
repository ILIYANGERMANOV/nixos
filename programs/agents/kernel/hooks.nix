# The state hooks, a hook module (hooks/default.nix) the base profile lists:
# each runs `state-hook <name>` (State.Protocol.Hook), which keeps the run's record as the
# agents work. `state` is this package, handed in as a module argument.
{ state, ... }:
let
  command = name: [
    "${state}/bin/state-hook"
    name
  ];
in
{
  hooks = {
    state-resume = {
      on = "sessionStart";
      command = command "resume";
    };
    state-spawn = {
      on = "beforeTool";
      tools = [ "delegate" ];
      command = command "spawn";
    };
    state-handback = {
      on = "beforeTool";
      tools = [ "handback" ];
      command = command "handback";
    };
    state-asked = {
      on = "afterTool";
      tools = [ "ask" ];
      command = command "asked";
    };
    # Binds the agent to its run: after a shell that ran `state init`, and after
    # a spawn, which binds the worker (State.Protocol.Binding).
    state-bind = {
      on = "afterTool";
      tools = [
        "shell"
        "delegate"
      ];
      command = command "bind";
    };
    # Denies a `state` call aimed at another run than the agent is bound to,
    # and a lead's write (an edit, a commit, a push, a PR, a spawn) before its
    # `state init` (State.Cli.Route.gate).
    state-route = {
      on = "beforeTool";
      tools = [
        "shell"
        "edit"
        "write"
        "delegate"
      ];
      command = command "route";
    };
    # How work begins: a spawned lead's run or a worker's brief, and a lead
    # skill typed or called (State.Cli.View.beginText), which marks its agent
    # a lead.
    state-begin-agent = {
      on = "agentStart";
      command = command "begin";
    };
    state-begin-prompt = {
      on = "promptExpansion";
      command = command "begin";
    };
    state-begin-skill = {
      on = "beforeTool";
      tools = [ "skill" ];
      command = command "begin";
    };
    # A child run whose agent stopped with no hand-back records it ended
    # (State.Cli.Shell.agentsEnded): at an agent's stop, its children not
    # running on too, and after a stop call, as a lead's stop of its child
    # fires no stop at the child.
    state-stop = {
      on = "agentStop";
      command = command "stop";
    };
    state-stop-call = {
      on = "afterTool";
      tools = [ "stopAgent" ];
      command = command "stop";
    };
  };
}
