# The software-factory server. Its agent.md reaches every factory session and
# role, its lead.md only the lead.
{ mkFragment, mkInstructions, ... }:
{
  # self-improve measures this box's own transcripts; android describes the
  # toolchain only the factory has; 10x-engineer relies on its session tools and
  # unattended rules.
  skills = [
    "10x-engineer"
    "self-improve"
    "android"
  ];
  instructions = mkInstructions {
    forAll = [
      (mkFragment {
        layer = "context";
        file = ./agent.md;
      })
    ];
    forLead = [
      (mkFragment {
        layer = "context";
        file = ./lead.md;
      })
    ];
  };
}
