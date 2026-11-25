# agent-hook-opencode: what the harness plugin runs for a profile's hooks. It
# translates the plugin's envelope to the neutral contract and back, around the
# frontend's dispatcher, imported in process. See opencode_adapter.py.
#
# It needs no OpenCode package, so python-tests builds it on every system.
{
  pkgs,
  # agent_hook.py as a Python library, from programs/agents.
  agentHook,
  # codegen/tools.nix: OpenCode's tools by their vendor-free name.
  tools,
}:

{
  toolsFile = pkgs.writeText "opencode-tools.json" (builtins.toJSON tools);

  # flake8 off: `python-lint` and `python-types` are the Python gate.
  bin = pkgs.writers.writePython3Bin "agent-hook-opencode" {
    doCheck = false;
    libraries = [ agentHook ];
  } (builtins.readFile ./opencode_adapter.py);
}
