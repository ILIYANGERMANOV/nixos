{ role, ... }:
{
  description = "One review agent under a review-lead: reads a diff against its brief and returns findings. Changes nothing.";
  instructions = [ (role ./role.md) ];
  capabilities = [
    "read"
    "shell"
  ];
}
