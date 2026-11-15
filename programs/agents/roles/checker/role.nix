# medium: waiting on a check needs no large model, which is the point of it.
{ role }:
{
  description = "Runs one long check its prompt names and hands back pass, or the failing check and its key log lines. Changes nothing.";
  instructions = [ (role ./role.md) ];
  tier = "medium";
}
