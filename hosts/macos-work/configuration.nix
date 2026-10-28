_: {
  networking.hostName = "macos-work";

  # Determinate Nix manages its own daemon — disable nix-darwin's Nix management to avoid conflict.
  nix.enable = false;

  myConfig = {
    user = {
      name = "iliyan-coinlist";
      fullName = "Iliyan Germanov";
      email = "iliyan@coinlist.co";
    };

    secrets = {
      # Work-only: macos-main deliberately does not provide this, so the Figma
      # MCP server is absent there rather than fed a placeholder token.
      figma-token = { };

      # Work-only: the throwaway Sepolia wallet /qa signs dApp flows with.
      # Claude sessions get its path as QA_EVM_KEY_FILE; other hosts report
      # the wallet as unavailable.
      qa-sepolia-key = { };
    };
  };

  system.stateVersion = 6;
}
