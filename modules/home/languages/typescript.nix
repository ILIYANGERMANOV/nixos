{ pkgs, ... }:
{
  home.packages = with pkgs; [
    nodejs_24
    pnpm
    typescript-language-server
    vscode-langservers-extracted
    biome
  ];
}
