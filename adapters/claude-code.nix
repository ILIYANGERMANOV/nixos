{
  root,
  pkgs,
  inputs,
  lib ? pkgs.lib,
  theme ? "auto",
  # name -> decrypted-file path, for the secrets THIS host provides. Paths only,
  # never values. programs/agents drops what needs a secret this host lacks.
  secrets ? { },
}:

import "${root}/programs/claude-code" {
  inherit
    pkgs
    lib
    theme
    ;
  claude-code = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
  agents = import "${root}/adapters/agents.nix" {
    inherit
      root
      pkgs
      inputs
      lib
      secrets
      ;
  };
}
