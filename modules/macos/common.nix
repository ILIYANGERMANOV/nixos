{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Nix 2.34.9's Darwin sandbox profile overflows macOS's 64 KB limit for
  # drvs with ~1100+ inputs (NixOS/nix#16613, fixed in 2.35.5). Drop this
  # once nixpkgs' default `nix` is >= 2.35.5. Only where nix-darwin manages
  # Nix: hosts with `nix.enable = false` run Determinate Nix's own daemon.
  nix.package = lib.mkIf config.nix.enable pkgs.nixVersions.nix_2_35;

  # Only root and the primary user may push store paths to the daemon,
  # not every admin account (was "@admin").
  nix.settings.trusted-users = [
    "root"
    config.myConfig.user.name
  ];

  # Enable Touch ID for sudo (macOS only)
  security.pam.services.sudo_local.touchIdAuth = true;

  # Application firewall: drop unsolicited inbound connections, and stay
  # invisible to probes/pings (stealth mode).
  networking.applicationFirewall = {
    enable = true;
    enableStealthMode = true;
  };

  # Require the password immediately when the screen sleeps / screensaver starts.
  system.defaults.screensaver = {
    askForPassword = true;
    askForPasswordDelay = 0;
  };

  # nix-darwin requires zsh to be enabled at the system level for login shells
  programs.zsh.enable = true;

  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
    };
    casks = [
      "ghostty"
      "handy" # push-to-talk dictation, preset by modules/home/handy.nix
    ];
  };
}
