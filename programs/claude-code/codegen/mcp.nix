# MCP servers as Claude Code reads them from ~/.claude.json. The servers, their
# transports and which ones a host can run come from programs/agents
# (lib/mcp.nix); this file only writes them out. No derivations, which is what
# lets programs/claude-code/check.nix test the shape.
{ lib }:

let
  # How each transport is written into ~/.claude.json.
  #
  # Dispatch is an attrset keyed by the tag rather than an if/else chain, so a
  # transport nothing here handles aborts evaluation instead of falling through
  # to a wrong shape.
  #
  # A local server is Claude Code's `stdio`. Its env values are ${VAR}
  # REFERENCES - the literal string "${FIGMA_API_KEY}" - which Claude Code's
  # expandVars resolves from the process environment at startup. Neither the
  # secret values nor the paths they are read from touch ~/.claude.json.
  # "$" + "{" + envVar + "}" produces that literal in Nix without triggering
  # Nix's own string interpolation syntax.
  #
  # A remote server is Claude Code's `http`. It carries no env at all: its
  # `env = { }` exists for the availability rules, and emitting it here would be
  # noise in a file that only needs the type and the url. Claude Code runs the
  # OAuth flow on first use (`/mcp`) and stores the grant in the macOS Keychain -
  # on Linux, in ~/.claude/.credentials.json - under a key derived from the
  # server's name, type, url and headers. None of it lives in ~/.claude.json,
  # which is why the wrapper replacing .mcpServers wholesale on every launch
  # cannot lose it. Renaming a catalog entry or changing its url DOES orphan the
  # grant, costing one re-login.
  toWire = {
    local = server: {
      type = "stdio";
      inherit (server) command args;
      env = lib.mapAttrs (envVar: _: "$" + "{" + envVar + "}") server.env;
    };

    remote = server: {
      type = "http";
      inherit (server) url;
    };
  };

  # The mcpServers structure for ~/.claude.json.
  mkMcpStructure = servers: lib.mapAttrs (_: server: toWire.${server.type} server) servers;
in
{
  inherit mkMcpStructure;
}
