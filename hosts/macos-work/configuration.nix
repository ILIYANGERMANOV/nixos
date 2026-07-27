{ config, ... }: {
  networking.hostName = "macos-work";

  # Determinate Nix manages its own daemon — disable nix-darwin's Nix management to avoid conflict.
  nix.enable = false;

  myConfig.user = {
    name = "iliyan-coinlist";
    fullName = "Iliyan Germanov";
    email = "iliyan@coinlist.co";
  };

  sops.secrets.figma-token = {
    key = "figma-token-macos-work";
    owner = config.myConfig.user.name;
  };

  system.stateVersion = 6;
}
