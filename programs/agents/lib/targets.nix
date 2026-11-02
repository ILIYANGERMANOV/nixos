# Targets as a semigroup with an identity: what one setup places under $HOME,
# as target path (relative to $HOME) -> store path. A backend builds each part
# of a setup as such a map and combines them with `fold` only.
#
# One target claimed by two different sources is an eval error naming the path
# and both sources, never last-writer-wins: which writer runs last is an
# accident of order. The same source twice is the same file, so it passes.
{
  pkgs,
  lib,
}:

let
  fold = lib.foldl' append empty;

  empty = { };

  append =
    a: b:
    let
      conflicts = lib.filter (path: "${a.${path}}" != "${b.${path}}") (
        lib.attrNames (lib.intersectAttrs a b)
      );
    in
    if conflicts == [ ] then
      a // b
    else
      throw "targets: ${
        lib.concatMapStringsSep "; " (
          path: "~/${path} has two sources: ${a.${path}} and ${b.${path}}"
        ) conflicts
      }";

  check =
    let
      # Store paths, not derivations: `throws` forces its value all the way
      # down, and a derivation reaches all of nixpkgs.
      one = builtins.toFile "one" "1";
      two = builtins.toFile "two" "2";
      a = {
        "x/a" = one;
      };
      b = {
        "x/b" = two;
      };
      throws = import ./throws.nix;
    in
    assert lib.assertMsg (append empty a == a) "targets: empty is not a left identity";
    assert lib.assertMsg (append a empty == a) "targets: empty is not a right identity";
    assert lib.assertMsg (append a a == a) "targets: one source twice is not idempotent";
    assert lib.assertMsg (
      append (append a b) a == append a (append b a)
    ) "targets: append is not associative";
    assert lib.assertMsg (
      fold [
        a
        b
        a
      ] == append (append a b) a
    ) "targets: fold is not append";
    assert lib.assertMsg (
      append a b == {
        "x/a" = one;
        "x/b" = two;
      }
    ) "targets: append lost a target";
    assert lib.assertMsg (throws (
      append a {
        "x/a" = two;
      }
    )) "targets: one target with two sources did not throw";
    assert lib.assertMsg (throws (fold [
      a
      b
      { "x/b" = one; }
    ])) "targets: fold kept the last of two sources";
    pkgs.writeText "targets-check" "";
in
{
  inherit fold check;
}
