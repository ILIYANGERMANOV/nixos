# The flows' step table as the JSON the kernel reads (#360 call 16): plain
# eval, no derivation is read back.
{ pkgs }:
{
  steps = pkgs.writeText "steps.json" (builtins.toJSON (import ./steps.nix));
}
