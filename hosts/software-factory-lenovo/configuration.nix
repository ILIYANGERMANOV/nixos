_: {
  imports = [ ./disk-config.nix ];

  networking.hostName = "software-factory-lenovo";

  # ThinkPad T15p Gen 2: i7-11800H (8 cores, 16 threads), 64 GB.
  myConfig.factory.size = "large";

  system.stateVersion = "26.05";
}
