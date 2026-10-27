# What `just check` and the other repo recipes need beyond nix itself, so
# `nix develop -c just check` works in a fresh checkout. CI runs its checks in
# this shell too, so the two cannot drift.
{ pkgs, self }:
pkgs.mkShell {
  packages = with pkgs; [
    just
    statix
    deadnix
    (import "${self}/programs/deslop" { inherit pkgs; }).package
  ];
}
