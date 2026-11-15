{ inputs, root }:
let
  inherit (inputs.nixpkgs) lib;

  mkNixosSystem =
    hostname: system:
    {
      theme ? "auto",
      # A machine shared with other hosts, by name in `hardwareModules`.
      hardware ? null,
    }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs root; };
      modules = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        inputs.home-manager.nixosModules.home-manager
        inputs.lanzaboote.nixosModules.lanzaboote
        "${root}/modules/theme.nix"
        { myConfig.theme = theme; }
        "${root}/modules/nix.nix"
        "${root}/modules/home-manager.nix"
        "${root}/modules/secrets.nix"
        "${root}/modules/nixos/common.nix"
        "${root}/modules/nixos/desktop.nix"
        "${root}/modules/nixos/audio.nix"
        "${root}/modules/nixos/security/disk-encryption.nix"
        "${root}/modules/nixos/security/secure-boot.nix"
        "${root}/modules/nixos/user.nix"
      ]
      ++ lib.optional (hardware != null) hardwareModules.${hardware}
      ++ [ "${root}/hosts/${hostname}/configuration.nix" ];
    };

  # Each path is spelled out in full so `deslop` resolves the import.
  hardwareModules = {
    thinkpad-t15p = "${root}/modules/nixos/hardware/thinkpad-t15p.nix";
  };

  # A headless NixOS server: no desktop, audio, disk encryption or Secure Boot,
  # which all assume a machine you sit in front of. What a server needs instead
  # lives in modules/nixos/server, which no other builder imports. `platform`
  # names the machine underneath, a key of `serverPlatforms`.
  mkNixosServer =
    hostname: system:
    { platform }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs root; };
      modules = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        inputs.home-manager.nixosModules.home-manager
        "${root}/modules/theme.nix"
        "${root}/modules/nix.nix"
        "${root}/modules/home-manager.nix"
        "${root}/modules/secrets.nix"
        "${root}/modules/nixos/server"
        serverPlatforms.${platform}
        "${root}/modules/admin-keys.nix"
        "${root}/hosts/${hostname}/configuration.nix"
      ];
    };

  serverPlatforms = {
    hetzner = "${root}/modules/nixos/server/platforms/hetzner.nix";
    thinkpad-t15p = "${root}/modules/nixos/server/platforms/thinkpad-t15p.nix";
  };

  mkDarwinSystem =
    hostname: system:
    {
      theme ? "auto",
    }:
    inputs.nix-darwin.lib.darwinSystem {
      inherit system;
      specialArgs = { inherit inputs root; };
      modules = [
        inputs.sops-nix.darwinModules.sops
        inputs.home-manager.darwinModules.home-manager
        "${root}/modules/theme.nix"
        { myConfig.theme = theme; }
        "${root}/modules/nix.nix"
        "${root}/modules/home-manager.nix"
        "${root}/modules/secrets.nix"
        "${root}/modules/macos/common.nix"
        "${root}/modules/macos/user.nix"
        "${root}/modules/macos/yubikey.nix"
        "${root}/hosts/${hostname}/configuration.nix"
      ];
    };

  forAllSystems =
    f:
    lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] (
      system:
      f (
        import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }
      )
    );
in
{
  inherit
    mkNixosSystem
    mkNixosServer
    mkDarwinSystem
    forAllSystems
    ;
}
