# What `just check` and the other repo recipes need beyond nix itself, so
# `nix develop -c just check` works in a fresh checkout. CI runs its checks in
# this shell too, so the two cannot drift. Plus every tool the tech checks run,
# see programs/tech-checks/tools.nix.
{ pkgs, inputs }:
let
  techTools = import ../programs/tech-checks/tools.nix { inherit pkgs; };
in
pkgs.mkShell {
  packages =
    with pkgs;
    [
      just
      statix
      deadnix
      pnpm
      inputs.deslop.packages.${pkgs.stdenv.hostPlatform.system}.deslop
    ]
    ++ builtins.attrValues techTools;
}
