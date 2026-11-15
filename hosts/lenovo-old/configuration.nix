_: {
  imports = [ ./disk-config.nix ];

  networking.hostName = "lenovo-old";
  networking.networkmanager.enable = true;

  myConfig.user = {
    name = "iliyan";
    fullName = "Iliyan Germanov";
    email = "iliyan.germanov971@gmail.com";
  };

  system.stateVersion = "25.11";
}
