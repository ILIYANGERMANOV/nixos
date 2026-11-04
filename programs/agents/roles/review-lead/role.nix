# Spawns the `reviewer`s. It needs the Trivial rule: its sweep reads it.
{ role, topics }:
{
  description = "Runs one pass of pragmatic-review: aims reviewer agents at a diff, judges what they bring back and reports. Changes no code.";
  instructions = [
    (role ./role.md)
    topics.trivial
  ];
  capabilities = [
    "read"
    "shell"
    "delegate"
  ];
  skills = [ "pragmatic-review" ];
}
