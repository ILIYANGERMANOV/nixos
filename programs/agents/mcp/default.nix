# The MCP server catalog. A profile names the servers it wants from here; a name
# not defined here aborts evaluation.
#
# Local servers name the SECRETS they need, never a path. Which hosts provide
# them is decided by modules/secrets.nix; a server whose secret a host does not
# declare is dropped silently when the profiles are folded for that host.
#
# Remote servers name no secrets and are therefore available everywhere: they
# authenticate out-of-band, once per machine. A host that should not reach one
# simply does not run a setup that lists it.
{ mkLocal, mkRemote }:
{
  figma = mkLocal {
    command = "npx";
    args = [
      "-y"
      "figma-developer-mcp"
      "--stdio"
    ];
    env.FIGMA_API_KEY = "figma-token";
  };

  # Read-write. Linear also serves /mcp/readonly, but the point of the pm profile
  # is filing and updating issues, not only reading them.
  linear = mkRemote { url = "https://mcp.linear.app/mcp"; };

  # The US data center endpoint; EU projects would need mcp.eu.amplitude.com.
  # OAuth, done out-of-band like every remote server.
  amplitude = mkRemote { url = "https://mcp.amplitude.com/mcp"; };

  # Coda's docs product, renamed after the Superhuman acquisition. The old
  # coda.io/apis/mcp endpoint still answers but is documented as deprecated.
  superhuman-docs = mkRemote { url = "https://docs.superhuman.com/apis/mcp"; };
}
