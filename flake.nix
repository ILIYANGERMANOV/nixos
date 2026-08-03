{
  description = "NixOS & dev-shell configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Intentionally NOT following nixpkgs: llm-agents tracks nixpkgs-unstable
    # so we always get the latest claude-code release. flake.lock pins the rev.
    llm-agents.url = "github:numtide/llm-agents.nix";
    herdr = {
      url = "github:ogulcancelik/herdr";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Not a flake — a plain repo of SKILL.md directories. `flake = false` keeps it
    # a regular store path, so skills can be discovered with builtins.readDir at
    # eval time. A fetchFromGitHub result could not: modules/nix.nix sets
    # allow-import-from-derivation = false. flake.lock pins the rev.
    mattpocock-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };
  };

  outputs =
    { self, ... }@inputs:
    let
      lib = import ./lib {
        inherit inputs;
        root = self;
      };
    in
    {
      # `nix fmt` — nixfmt (RFC 166) via a treefmt wrapper.
      formatter = lib.forAllSystems (pkgs: pkgs.nixfmt-tree);

      # `nix flake check` (run by `just check` in CI) validates every installed
      # SKILL.md: frontmatter present, name matches the directory, description
      # within the Agent Skills limit.
      checks = lib.forAllSystems (pkgs: {
        skills =
          (import ./lib/skills.nix {
            inherit inputs pkgs;
            root = self;
          }).check;

        # Spell check. Pinned to the locked nixpkgs deliberately: typos' dictionary
        # is its product and grows with every release, so a floating version could
        # turn CI red with no change to this repo. Sees only the committed
        # `.typos.toml`, never the private global allowlist.
        typos = (import ./programs/typos { inherit pkgs; }).mkCheck self;
      });

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
