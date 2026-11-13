# nix develop .#factory-demo: this repo's agent harness for anyone who clones
# it. `claude-demo` keeps its own config dir, see programs/claude-code.
{
  pkgs,
  inputs,
  self,
}:
let
  claudeCode = import "${self}/adapters/claude-code.nix" {
    root = self;
    inherit pkgs inputs;
  };
in
pkgs.mkShell {
  packages = with pkgs; [
    claudeCode.demo
    git
    gh
    ripgrep
    just
  ];
  shellHook = ''
    echo "Run claude-demo: Claude Code with this repo's skills, subagents and hooks."
    echo "It keeps its config, login included, in ''${XDG_STATE_HOME:-~/.local/state}/claude-demo; set CLAUDE_DEMO_DIR to move it."
  '';
}
