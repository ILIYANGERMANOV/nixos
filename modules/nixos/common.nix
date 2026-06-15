{ pkgs, ... }: {
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  services.openssh.enable = false;

  environment.systemPackages = with pkgs; [
    sops
    age
  ];
}
