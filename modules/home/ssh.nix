{ pkgs, lib, ... }: {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false; # opt out of the legacy "*" defaults; declare them explicitly below

    # New HM schema: keyed by Host/Match pattern, values are upstream OpenSSH
    # directive names. Booleans render to yes/no.
    settings = {
      "github.com" = {
        User = "git";
        IdentityFile = "~/.ssh/id_ed25519";
        IdentitiesOnly = true; # only offer this key, never spray other agent keys at GitHub
      };

      # Written last (after specific blocks) so per-host directives win.
      "*" = lib.hm.dag.entryAfter [ "github.com" ] (
        {
          IdentityFile = "~/.ssh/id_ed25519";
          AddKeysToAgent = "yes";
          ForwardAgent = false; # never expose the agent to remote hosts
          Compression = false;
          ServerAliveInterval = 60;
          ServerAliveCountMax = 3;
          HashKnownHosts = true;
        }
        // lib.optionalAttrs pkgs.stdenv.isDarwin {
          UseKeychain = "yes"; # darwin-only keyword; would break the Linux host's openssh
        }
      );
    };
  };
}
