{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # The nixpkgs default, 3.13. The /self-improve analyzer needs 3.13 and
    # macOS ships 3.9.
    python3
    ruff
    basedpyright
  ];
}
