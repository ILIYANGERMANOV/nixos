{ role, topics, ... }:
{
  description = "Implements one slice of a plan, commits and pushes.";
  instructions = [
    (role ./role.md)
    (role ../shared/building.md)
    topics.quality
  ];
  capabilities = [
    "read"
    "edit"
    "shell"
  ];
  skills = [ "engineering" ];
}
