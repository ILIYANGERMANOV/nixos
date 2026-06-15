{ root, inputs, pkgs, lib, themeConfig, ... }:

let
  claude-code = inputs.llm-agents.packages.${pkgs.system}.claude-code;
  claude = import "${root}/programs/claude-code" {
    inherit pkgs lib claude-code;
    theme = themeConfig;
  };
in
{
  home.packages = claude.packages;

  home.activation.claudeCodeSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" ] claude.activationScript;
}
