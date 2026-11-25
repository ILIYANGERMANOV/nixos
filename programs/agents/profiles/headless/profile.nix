# A run with no user present, such as a CI job: the lead answers every
# question itself and never ends its turn while work remains. Its lead.md, for
# the lead only, overrides the Asking rules. Subagents are unchanged: they
# still hand their questions up to the lead.
{ mkFragment, mkInstructions, ... }:
{
  instructions = mkInstructions {
    forLead = [
      (mkFragment {
        layer = "context";
        file = ./lead.md;
      })
    ];
  };
}
