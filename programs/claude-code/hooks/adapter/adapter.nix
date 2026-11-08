# agent-hook-claude: what Claude's settings run for a profile's hooks. It
# translates Claude's hook JSON to the neutral contract and back, around the
# frontend's dispatcher, imported in process: one Python start per event,
# however many hooks it has. See claude_adapter.py.
{
  pkgs,
  # agent_hook.py as a Python library, from programs/agents.
  agentHook,
  # codegen/tools.nix: Claude's tools by their vendor-free name.
  tools,
}:

let
  toolsFile = pkgs.writeText "claude-hook-tools.json" (builtins.toJSON tools);

  # flake8 off: `python-lint` and `python-types` are the Python gate.
  bin = pkgs.writers.writePython3Bin "agent-hook-claude" {
    doCheck = false;
    libraries = [ agentHook ];
  } (builtins.readFile ./claude_adapter.py);
in
{
  inherit bin toolsFile;

  # The settings entry running the hooks of `manifest` (agents.hooks.manifest).
  hookFor = manifest: {
    type = "command";
    command = "${bin}/bin/agent-hook-claude ${toolsFile} ${manifest}";
  };
}
