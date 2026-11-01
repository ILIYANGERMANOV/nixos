{
  pkgs,
  inputs,
  self,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  nvim = inputs.nixvim.legacyPackages.${system}.makeNixvimWithModule {
    inherit pkgs;
    module = import "${self}/programs/nvim";
    extraSpecialArgs = {
      profile = "sops";
      root = self;
    };
  };
  shellCheck = import "${self}/programs/shell-check" { inherit pkgs; };
  claudeCode = import "${self}/adapters/claude-code.nix" {
    root = self;
    inherit pkgs inputs;
  };
in
pkgs.mkShell {
  packages =
    with pkgs;
    [
      just # run Just recipes (just install <host>, just enroll-secure-boot, etc.)
      git # clone the repo on the live ISO
      age # age-keygen for generate-age-key recipe
      nvim # edit secrets and config files
      sops # encrypt/decrypt secrets (just edit-secrets, just set-password-hash)
      ssh-to-age # convert SSH host keys to age keys
      mkpasswd # hash passwords for just set-password-hash (yescrypt)
    ]
    ++ pkgs.lib.optionals isLinux [
      sbctl # Secure Boot key creation and enrollment (Linux-only)
    ]
    ++ claudeCode.packages;
  shellHook = ''
    export EDITOR=nvim
    export SOPS_AGE_KEY_FILE="/var/lib/sops-age/keys.txt"
    ${claudeCode.activationScript}

    ${shellCheck.fragment ./nixos-install-banner.sh}
  '';
}
