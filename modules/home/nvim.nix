{ root, themeConfig, pkgs, ... }:
let
  nvimStyle = {
    dark = "catppuccin_dark";
    light = "catppuccin_light";
    auto = "auto";
  }.${themeConfig};
in
{
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    # useGlobalPkgs already builds nixvim against the system pkgs; pin the
    # source to match so nixvim doesn't warn about its follows-overridden nixpkgs.
    nixpkgs.source = pkgs.path;
    myNixVim.style = nvimStyle;
    imports = [
      (import "${root}/programs/nvim")
    ];
  };
}
