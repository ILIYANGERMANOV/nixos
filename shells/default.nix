# What `just check` and the other repo recipes need beyond nix itself, so
# `nix develop -c just check` works in a fresh checkout. CI runs its checks in
# this shell too, so the two cannot drift. It also carries every tool the tech
# checks run, from the same expressions they use, so `ruff`, `basedpyright`,
# `pytest` and the rest run by hand (or through direnv's `.envrc`) at CI's
# versions.
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
