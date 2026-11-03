{ role, ... }:
{
  description = "Checks work against its prompt and returns findings: a review brief, a skill dry run, QA evidence or a 10x audit. Changes nothing.";
  instructions = [ (role ./role.md) ];
  capabilities = [
    "read"
    "shell"
  ];
}
