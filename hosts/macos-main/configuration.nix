{ config, ... }: {
  networking.hostName = "macos-main";

  myConfig.user = {
    name = "iliyangermanov";
    fullName = "Iliyan Germanov";
    email = "iliyan.germanov971@gmail.com";
  };

  sops.secrets.figma-token = { key = "figma-token-macos-main"; owner = config.myConfig.user.name; };

  system.stateVersion = 6;
}
