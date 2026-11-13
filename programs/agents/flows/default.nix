# The flows' step table: `table` as written, for lib/derive.nix, and `steps`,
# the JSON the kernel reads (#360 call 16): plain eval, no derivation is read
# back. The kernel gets the rows of its two flows only; the `other` rows are
# for the derivation.
{ pkgs, lib }:
let
  table = import ./steps.nix;
in
{
  inherit table;
  steps = pkgs.writeText "steps.json" (
    builtins.toJSON (lib.filterAttrs (_: row: !lib.elem "other" row.flows) table)
  );
}
