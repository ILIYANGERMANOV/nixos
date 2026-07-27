{
  root,
  pkgs,
  inputs,
  lib ? pkgs.lib,
  theme ? "auto",
}:

import "${root}/programs/claude-code" {
  inherit pkgs lib theme;
  claude-code = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
}
