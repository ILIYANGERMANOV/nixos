{ role, topics, ... }:
{
  description = "Runs the preloaded refactor skill on a diff without changing behaviour, then checks, commits and pushes.";
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
  skills = [
    "refactor"
    "engineering"
  ];
}
