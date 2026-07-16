{ pkgs, lib, ... }: {
  # FIDO-capable OpenSSH (built with libfido2) + ykman on PATH.
  # macOS ships /usr/bin/ssh (LibreSSL) which CANNOT use ed25519-sk keys, so the
  # Nix openssh must shadow it. See docs/SSH.md.
  home.packages = [
    pkgs.openssh
    pkgs.yubikey-manager # ykman: firmware check, FIDO2 PIN, resident-credential mgmt
  ];

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false; # opt out of the legacy "*" defaults; declare them explicitly below

    # New HM schema: keyed by Host/Match pattern, values are upstream OpenSSH
    # directive names. Booleans render to yes/no.
    settings = {
      "github.com" = {
        User = "git";
        # Hardware-backed key-handle stubs. Primary first; ssh silently skips a
        # missing file, so plugging in either YubiKey (or the backup) just works.
        IdentityFile = [ "~/.ssh/id_ed25519_sk" "~/.ssh/id_ed25519_sk_backup" ];
        IdentitiesOnly = true; # only offer these keys, never spray other agent keys at GitHub
      };

      # Written last (after specific blocks) so per-host directives win.
      "*" = lib.hm.dag.entryAfter [ "github.com" ] {
        IdentityFile = [ "~/.ssh/id_ed25519_sk" "~/.ssh/id_ed25519_sk_backup" ];
        # No AddKeysToAgent / UseKeychain: sk stubs carry no on-disk secret and
        # require a physical tap per operation — there is nothing to cache.
        ForwardAgent = false; # never expose the agent to remote hosts
        Compression = false;
        ServerAliveInterval = 60;
        ServerAliveCountMax = 3;
        HashKnownHosts = true;
      };
    };
  };
}
