{ pkgs, userConfig, ... }: {
  home.packages = with pkgs; [
    pre-commit
    gh
  ];

  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      user = {
        inherit (userConfig) email;
        name = userConfig.fullName;
        signingkey = "~/.ssh/id_ed25519.pub"; # this machine's own SSH key
      };
      init.defaultBranch = "main";

      # Normalize CRLF to LF on commit, leave the working tree untouched on checkout.
      core.autocrlf = "input";

      # Sign commits and tags with SSH by default (GitHub shows a "Verified" badge).
      gpg.format = "ssh";
      commit.gpgsign = true;
      tag.gpgsign = true;
    };
  };
}
