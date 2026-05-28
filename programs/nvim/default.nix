{ pkgs, ... }:

{
  imports = [
    ./core/window.nix
    ./core/theme.nix
    ./core/file-tree.nix
    ./core/git.nix
    ./core/format.nix
    ./core/auto-complete.nix
    ./core/search.nix
    ./core/lsp.nix
    ./core/clipboard.nix
    ./core/context-aware-keymaps.nix
    ./languages/nix.nix
    ./languages/mdc.nix
    ./languages/typescript.nix
    ./languages/haskell.nix
    ./languages/yaml.nix
    ./languages/elixir.nix
    ./languages/d2.nix
  ];

  env = {
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";
  };

  globals = {
    mapleader = " ";
    maplocalleader = " ";
  };

  opts = {
    number = true;
    relativenumber = true;
    shiftwidth = 2;
    expandtab = true;
    smartindent = true;
    breakindent = true;
    ignorecase = true;
    smartcase = true;
  };

  keymaps = import ./keymaps.nix;

  plugins = {
    lualine.enable = true;
  };

  extraPackages = [
    pkgs.xdg-utils
  ];
}
