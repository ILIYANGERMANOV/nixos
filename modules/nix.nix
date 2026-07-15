_: {
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;

    # Isolate builds from the host: no access to your files or the network.
    # Escape hatch for a rare darwin build that needs it: --option sandbox relaxed
    sandbox = true;

    # Block Import From Derivation: evaluating a flake can no longer trigger
    # arbitrary builds/code execution before you approve a build (supply-chain).
    allow-import-from-derivation = false;
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };
}
