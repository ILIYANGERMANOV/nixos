{
  root,
  themeConfig,
  pkgs,
  lib,
  ...
}:
let
  typos = import "${root}/programs/typos" { inherit pkgs lib; };

  nvimStyle =
    {
      dark = "catppuccin_dark";
      light = "catppuccin_light";
      auto = "auto";
    }
    .${themeConfig};
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
      # Shared with modules/home/typos.nix so the allowlist path has one source
      # of truth; nixvim modules don't get `root`, so it has to be passed in.
      { _module.args.typos = typos; }
    ];
  };
}
