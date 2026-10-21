# Nix for a machine that runs untrusted builds on behalf of agents.
{ config, lib, ... }:
let
  gib = n: n * 1024 * 1024 * 1024;
in
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

      # Two builds at a time, four cores each: a CX43 has 8 shared vCPUs and the
      # agents themselves need some.
      max-jobs = 2;
      cores = 4;

      # Collect garbage during builds before the disk fills up.
      min-free = gib 10;
      max-free = gib 30;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
}
