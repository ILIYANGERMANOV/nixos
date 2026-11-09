# A hook module as a profile lists it, for the checks: one file, one hook.
{
  hooks.resume = {
    on = "sessionStart";
    command = [ "resume" ];
  };
}
