# Nix for a machine that runs untrusted builds on behalf of agents.
# Build parallelism and disk headroom are sized in resources.nix.
{ config, lib, ... }:
{
  nix = {
    settings = {
      # modules/nix.nix allows "relaxed" for a darwin package that needs the
      # network. Here every build is sandboxed, without exceptions.
      sandbox = lib.mkForce true;

      # The agent account may use the daemon but is never trusted: a trusted
      # user can add substituters, import unsigned paths and turn the sandbox
      # off, which amounts to root. Deploys copy only content-addressed paths
      # (sources and .drv files), which needs no trust either.
      allowed-users = [
        "root"
        "@wheel"
        config.myConfig.user.name
      ];
      trusted-users = [ "root" ];
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
}
