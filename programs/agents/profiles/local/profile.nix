# A machine the user sits at, the Macs: 10x-engineer without the factory's
# session tools. Its lead.md, for the lead only, says what differs here.
{ mkFragment, mkInstructions, ... }:
{
  skills = [ "10x-engineer" ];
  instructions = mkInstructions {
    forLead = [
      (mkFragment {
        layer = "context";
        file = ./lead.md;
      })
    ];
  };
}
