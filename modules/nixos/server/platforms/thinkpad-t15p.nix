# A ThinkPad T15p Gen 2 run as an always-on server with its lid closed:
# nothing may suspend it, a hang or panic reboots it, and after a power cut it
# boots unattended (the BIOS powers on with AC, see docs/SOFTWARE-FACTORY.md).
{ config, ... }:
{
  imports = [ ../../hardware/thinkpad-t15p.nix ];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      timeout = 1;
    };
    kernelParams = [
      # Blank the console after a minute, so the panel backlight is off under
      # the closed lid instead of heating the keyboard deck.
      "consoleblank=60"
      # Reboot 10 s after a kernel panic instead of hanging until someone
      # comes by.
      "panic=10"
    ];
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
  };

  # Closing the lid, the sleep keys and idling do nothing, and systemd refuses
  # to suspend or hibernate at all, whoever asks.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    IdleAction = "ignore";
  };
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  # The hardware watchdog reboots the box when systemd stops responding.
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";

  services.thermald.enable = true;

  # TLP's own AC defaults (balanced, turbo allowed) suit a plugged-in box. The
  # battery only bridges power cuts, so it is held between 75 and 80 % to
  # slow its wear from sitting at full charge.
  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 75;
      STOP_CHARGE_THRESH_BAT0 = 80;
    };
  };

  networking = {
    # Ethernet gets DHCP on its own; Wi-Fi joins the network in the wifi-env
    # secret (WIFI_SSID, WIFI_PSK).
    networkmanager = {
      enable = true;
      wifi.powersave = false;
      # Public resolvers only: egress rejects the agent account's traffic to
      # private ranges, so a router's resolver would break tools that read
      # resolv.conf themselves, such as Go's.
      dns = "none";
      ensureProfiles = {
        environmentFiles = [ config.sops.secrets.wifi-env.path ];
        profiles.wifi = {
          connection = {
            id = "wifi";
            type = "wifi";
          };
          wifi = {
            mode = "infrastructure";
            ssid = "$WIFI_SSID";
          };
          wifi-security = {
            key-mgmt = "wpa-psk";
            psk = "$WIFI_PSK";
          };
          ipv4.method = "auto";
          ipv6.method = "auto";
        };
      };
    };
    nameservers = [
      "1.1.1.1"
      "9.9.9.9"
    ];
  };

  myConfig.secrets.wifi-env.owner = "root";
}
