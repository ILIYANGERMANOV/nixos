{
  pkgs,
  inputs,
  self,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  nvim = inputs.nixvim.legacyPackages.${system}.makeNixvimWithModule {
    inherit pkgs;
    module = import "${self}/programs/nvim";
    extraSpecialArgs = {
      profile = "nix";
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
      just # run darwin-install recipes
      git # clone / work with the repo
      nvim # edit host config and flake.nix before bootstrapping
      nil # Nix LSP (inside nvim)
      nixfmt # Nix formatter (inside nvim)
      age # inspect / validate the SOPS age key
      sops # edit secrets/ (just edit-secrets)
    ]
    ++ claudeCode.packages;
  shellHook = ''
    ${claudeCode.activationScript}
    export SOPS_AGE_KEY_FILE="/var/lib/sops-age/keys.txt"

    ${shellCheck.fragment ./darwin-install-banner.sh}
  '';
}
