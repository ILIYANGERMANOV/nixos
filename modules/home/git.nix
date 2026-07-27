{
  pkgs,
  lib,
  userConfig,
  ...
}:
{
  home.packages = with pkgs; [
    pre-commit
    gh
  ];

  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      # git-lfs defaults to spinning up its OWN ssh control connection, bypassing
      # the OpenSSH ControlMaster configured in ssh.nix and forcing an extra
      # YubiKey ceremony per push. Disable it so LFS reuses the shared master.
      lfs.ssh.autoMultiplex = false;

      user = {
        inherit (userConfig) email;
        name = userConfig.fullName;
        signingkey = "~/.ssh/id_ed25519_sk.pub"; # this machine's own YubiKey-backed SSH key
      };
      init.defaultBranch = "main";

      # Normalize CRLF to LF on commit, leave the working tree untouched on checkout.
      core.autocrlf = "input";

      # Force the FIDO-capable Nix OpenSSH for both transport and signing. Without
      # this, git (or a GUI client) could fall back to macOS's /usr/bin/ssh, which
      # cannot use ed25519-sk keys and would break auth + signing.
      core.sshCommand = lib.getExe pkgs.openssh;
      gpg.ssh.program = lib.getExe' pkgs.openssh "ssh-keygen";

      # Sign commits and tags with SSH by default (GitHub shows a "Verified" badge).
      gpg.format = "ssh";
      commit.gpgsign = true;
      tag.gpgsign = true;
    };
  };
}
