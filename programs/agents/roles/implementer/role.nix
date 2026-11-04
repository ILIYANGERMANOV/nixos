{ role, topics, ... }:
{
  description = "Implements one slice of a plan, commits and pushes. Splits a large slice across fresh implementers.";
  instructions = [
    (role ./role.md)
    (role ../shared/building.md)
    topics.quality
  ];
  capabilities = [
    "read"
    "edit"
    "shell"
    "delegate"
  ];
  skills = [ "engineering" ];
}
