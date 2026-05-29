{
  description = "NixOS & dev-shell configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixvim = {
      url = "github:nix-community/nixvim/nixos-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, ... }@inputs:
    let
      lib = import ./lib { inherit inputs; root = self; };
    in
    {
      devShells = lib.forAllSystems (pkgs: {
        nixos-install = import ./shells/nixos-install.nix { inherit pkgs inputs self; };
        darwin-install = import ./shells/darwin-install.nix { inherit pkgs inputs self; };
      });

      nixosConfigurations = {
        lenovo-old = lib.mkNixosSystem "lenovo-old" "x86_64-linux" { };
        # next-host = lib.mkNixosSystem "next-host" "x86_64-linux" { };
      };

      darwinConfigurations = {
        macos-main = lib.mkDarwinSystem "macos-main" "aarch64-darwin" { };
        macos-work = lib.mkDarwinSystem "macos-work" "aarch64-darwin" { };
      };
    };
}
