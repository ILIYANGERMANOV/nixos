# Three agents compiling Haskell and Next.js at once can exhaust 16 GB. These
# limits make sure the box degrades by killing a build, not sshd or tailscaled.
{ config, ... }:
let
  uid = toString config.users.users.${config.myConfig.user.name}.uid;
in
{
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Backstop for when zram is full.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 8 * 1024;
    }
  ];

  systemd = {
    # Under sustained memory pressure, oomd kills the heaviest process in a user
    # slice - in practice a compiler - instead of letting the kernel choose.
    oomd = {
      enable = true;
      enableUserSlices = true;
    };

    # Everything the agent account runs: Claude Code, cabal, next build.
    slices."user-${uid}".sliceConfig = {
      MemoryHigh = "12G";
      MemoryMax = "13G";
    };

    # Nix builds run in the daemon's cgroup, not the user's, so they are capped
    # separately.
    services.nix-daemon.serviceConfig = {
      MemoryHigh = "7G";
      MemoryMax = "8G";
    };
  };
}
