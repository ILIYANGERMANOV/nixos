{ role, topics, ... }:
{
  description = "Gathers facts on one topic from code, docs, web and small /tmp probes. Writes a notes file and hands back a ranked file:line index. Changes nothing else.";
  instructions = [
    (role ./role.md)
    topics.quality
  ];
  capabilities = [
    "read"
    "shell"
    "web"
  ];
  skills = [ "researcher" ];
  effort = "medium";
}
