{ role, ... }:
{
  description = "Fixes the review rows, failing check or rebase its brief names, and commits. Spawns nobody.";
  instructions = [
    (role ./role.md)
    (role ../shared/building.md)
  ];
  capabilities = [
    "read"
    "edit"
    "shell"
  ];
  skills = [ "engineering" ];
}
