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
  };
}
