# Lenovo ThinkPad T15p Gen 2 (i7-11800H, NVMe): what nixos-generate-config
# detects, minus the file systems, which each host's disk-config owns. Shared by
# every host on this laptop, whether a desktop or a server.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];
}
