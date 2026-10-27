# The tailnet is the only way in. The node joins as tag:factory, and the policy
# in tailscale/policy.hujson grants nothing FROM that tag, so the box cannot
# open connections to any other device on the tailnet.
#
# --ssh:             Tailscale SSH serves port 22 on the tailnet address. It
#                    authenticates the tailnet identity, and the policy maps
#                    that identity to the agent account only.
# --accept-dns=false: the agent account is barred from 100.64.0.0/10 by
#                    egress.nix, which includes MagicDNS at 100.100.100.100.
#                    The box resolves through Hetzner's resolvers instead.
#
# UDP 41641 stays closed: Tailscale still connects through NAT traversal and
# DERP, with nothing listening on the public interface.
{ config, ... }:
{
  services.tailscale = {
    enable = true;
    openFirewall = false;
    authKeyFile = config.sops.secrets.tailscale-authkey.path;
    extraUpFlags = [
      "--ssh"
      "--advertise-tags=tag:factory"
      "--accept-dns=false"
    ];
  };

  # Every root path in the October 2026 Tailscale SSH flaws (Unix-socket -L,
  # -R socket replacement, the check/use race on bind and dial) goes through
  # SSH forwarding: https://tailscale.com/ssh-investigation-update
  # This turns off TCP and Unix-socket -L/-R and agent forwarding (-A); shells,
  # scp and sftp still work. It stays after the fix: nothing here forwards, and
  # previews are reached directly on the ports below.
  systemd.services.tailscaled.environment.TS_SSH_DISABLE_FORWARDING = "1";

  # One-off, pre-approved, tagged key. Once the node has joined, its identity
  # lives in /var/lib/tailscale and the key can be revoked in the admin console.
  myConfig.secrets.tailscale-authkey.owner = "root";

  # App previews: dev servers the agents start, reachable from your own devices
  # over the tailnet and from nowhere else.
  networking.firewall.interfaces.tailscale0.allowedTCPPortRanges = [
    {
      from = 3000;
      to = 3099;
    }
  ];
}
