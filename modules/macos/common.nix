_: {
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@admin" ];
  };

  # Enable Touch ID for sudo (macOS only)
  security.pam.services.sudo_local.touchIdAuth = true;

  # nix-darwin requires zsh to be enabled at the system level for login shells
  programs.zsh.enable = true;

  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = false;
      cleanup = "zap";
    };
    casks = [
      "ghostty"
    ];
  };
}
