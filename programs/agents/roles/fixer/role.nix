{ role, ... }:
{
  description = "Fixes the review rows, failing check, rebase or PR body its brief names, and commits. Spawns nobody.";
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
