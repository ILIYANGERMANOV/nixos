# A hook module as a profile lists it, for the checks: one file, one hook.
{
  hooks.spawn = {
    on = "beforeTool";
    tools = [ "delegate" ];
    command = [ "spawn" ];
  };
}
