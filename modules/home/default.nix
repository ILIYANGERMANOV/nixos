{ pkgs, userConfig, ... }: {
  imports = [
    ./nvim.nix
    ./terminal.nix
    ./claude-code.nix
    ./bitwarden.nix
    ./gitui.nix
    ./git.nix
    ./kalker.nix
    ./languages/typescript.nix
    ./languages/haskell.nix
    ./languages/nix.nix
    ./languages/yaml.nix
  ];

  home = {
    username = userConfig.name;
    homeDirectory =
      if pkgs.stdenv.isDarwin
      then "/Users/${userConfig.name}"
      else "/home/${userConfig.name}";
    stateVersion = "25.11";
    packages = with pkgs; [
      wget
      curl
      htop
      firefox # Useful white setting up NixOS
      just
      age # inspect / validate the SOPS age key
      sops # edit secrets/secrets.yaml
    ];
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    package = pkgs.direnv.overrideAttrs (_: { doCheck = false; });
  };

}
