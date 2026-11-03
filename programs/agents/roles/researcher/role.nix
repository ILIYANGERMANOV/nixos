{ role, ... }:
{
  description = "Read-only research on one topic. Answers listed questions with bounded reads, writes a notes file and hands back a ranked file:line index. Changes nothing else.";
  instructions = [ (role ./role.md) ];
  capabilities = [
    "read"
    "shell"
    "web"
  ];
  skills = [ "researcher" ];
  effort = "medium";
}
