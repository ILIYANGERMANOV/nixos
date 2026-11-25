{
  root,
  pkgs,
  inputs,
  lib ? pkgs.lib,
}:

import "${root}/programs/opencode" {
  inherit pkgs lib;
  inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) opencode;
  agents = import "${root}/adapters/agents.nix" {
    inherit
      root
      pkgs
      inputs
      lib
      ;
  };
}
