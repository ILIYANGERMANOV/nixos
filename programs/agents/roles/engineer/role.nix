# Every capability: it orchestrates a whole task's lifecycle and invokes
# skills it does not preload with the Skill tool. It needs the Trivial rule: it
# sets Size, and the Quality table.
{ role, topics, ... }:
{
  description = "Delivers one task as a PR with the preloaded engineer skill. Its prompt names a brief file.";
  instructions = [
    (role ./role.md)
    topics.trivial
    topics.quality
  ];
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
