_: {
  imports = [ ./disk-config.nix ];

  networking.hostName = "software-factory";

  # Hetzner CX33 (4 vCPU, 8 GB). Switch to "standard" on an 8 vCPU / 16 GB
  # machine.
  myConfig.factory.size = "medium";

  system.stateVersion = "26.05";
}
