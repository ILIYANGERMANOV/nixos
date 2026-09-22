# Pure MCP catalog logic: declaring servers, resolving them against the secrets
# a host provides, and picking one flavor's subset. No derivations and no
# wrappers, which is what lets programs/claude-code/check.nix exercise all of it
# against a synthetic catalog and a synthetic `secrets`.
#
# `secrets` is the name -> decrypted-file path attrset for the secrets THIS host
# provides. Paths only, never values.
{
  lib,
  secrets ? { },
}:

let

  # Constructs a catalog entry.
  #
  # `env` maps an environment variable to the NAME of the secret that fills it,
  # never to a path and never to a value: which hosts provide that secret is
  # decided by modules/secrets.nix, and this layer only ever sees the
  # name-to-path attrset it was handed, so programs/ stays host-agnostic.
  #
  # A server needing no secrets declares no `env`. That is an empty attrset
  # rather than a special case: every rule below reads as "for all the secrets
  # this server names", which holds vacuously for none.
  mkMcpServer =
    {
      command,
      args,
      env ? { },
    }:
    {
      inherit command args env;
    };

  # The servers this host can actually run, with every secret name resolved to
  # its decrypted-file path.
  #
  # A server whose secret the host does not declare is dropped here, so a flavor
  # listing it gets nothing at all rather than a server fed a placeholder token.
  # Availability is all-or-nothing: a server naming two secrets needs both.
  availableServers = catalog: lib.mapAttrs (_: resolve) (lib.filterAttrs (_: isAvailable) catalog);

  isAvailable = server: lib.all (name: secrets ? ${name}) (lib.attrValues server.env);

  resolve = server: server // { env = lib.mapAttrs (_: name: secrets.${name}) server.env; };

  # The subset of `available` that one flavor asked for.
  #
  # Requests are validated against every DEFINED name and then read from the
  # AVAILABLE ones, so a typo aborts evaluation the way an unknown skill name
  # does, while a server this host has no secret for stays silent - which is the
  # point of dropping it.
  selectServers =
    {
      flavor,
      known,
      available,
      requested,
    }:
    let
      unknown = lib.subtractLists known requested;
    in
    if unknown != [ ] then
      throw ''
        claude flavor "${flavor}": unknown MCP server(s): ${lib.concatStringsSep ", " unknown}.
        Defined in mcpCatalog: ${lib.concatStringsSep ", " known}.
      ''
    else
      lib.filterAttrs (name: _: builtins.elem name requested) available;

  # The mcpServers structure for ~/.claude.json.
  #
  # Env values are ${VAR} REFERENCES - the literal string "${FIGMA_API_KEY}" -
  # which Claude Code's expandVars resolves from the process environment at
  # startup. Neither the secret values nor the paths they are read from touch
  # ~/.claude.json.
  #
  # "$" + "{" + envVar + "}" produces that literal in Nix without triggering
  # Nix's own string interpolation syntax.
  mkMcpStructure =
    servers:
    lib.mapAttrs (_: server: {
      type = "stdio";
      inherit (server) command args;
      env = lib.mapAttrs (envVar: _: "$" + "{" + envVar + "}") server.env;
    }) servers;
in
{
  inherit
    mkMcpServer
    availableServers
    selectServers
    mkMcpStructure
    ;
}
