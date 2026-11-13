# Checks grouped by technology: a flat attrset of `<tech>-<kind>` derivations,
# since `checks.<system>.<name>` must be a derivation and cannot nest. The prefix
# is the group `just tech <tech>` builds. None may touch a host, so a group
# evaluates in seconds. See docs/adr/0009-tech-checks.md.
{
  pkgs,
  claude,
  # The guards, which python-tests runs end to end.
  guards,
  # The Haskell kernel package, whose build runs its own tests.
  kernel,
}:
import ./shell.nix { inherit pkgs claude; }
// import ./ts.nix { inherit pkgs; }
// import ./python.nix {
  inherit
    pkgs
    claude
    guards
    ;
}
// import ./lua.nix { inherit pkgs; }
// import ./haskell.nix { inherit pkgs kernel; }
