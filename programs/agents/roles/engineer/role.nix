# Every capability: it orchestrates the whole delegated lifecycle and invokes
# skills it does not preload with the Skill tool.
{ role, ... }:
{
  description = "Delivers one delegated task as a PR with the preloaded engineer skill. Its prompt names a brief file.";
  instructions = [ (role ./role.md) ];
  capabilities = [
    "read"
    "edit"
    "shell"
    "web"
    "delegate"
    "skill"
  ];
  skills = [
    "engineer"
    "engineering"
  ];
}
