# MCP servers and secret files, without a wire format: declaring a server,
# picking servers by name, and narrowing both to the secrets a host provides.
# Each agent program writes the result out in its own format.
#
# `secrets` is the name -> decrypted-file path attrset for the secrets one host
# provides. Paths only, never values. It is an argument, never looked up, so this
# layer stays host-agnostic.
{
  pkgs,
  lib,
}:

let
  # A server is one of two transports, tagged by `type`.

  # A local server, which the agent spawns as a subprocess.
  #
  # `env` maps an environment variable to the NAME of the secret that fills it,
  # never to a path and never to a value: which hosts provide that secret is
  # decided by modules/secrets.nix.
  #
  # A server needing no secrets declares no `env`. That is an empty attrset
  # rather than a special case: every rule below reads as "for all the secrets
  # this server names", which holds vacuously for none.
  mkLocal =
    {
      command,
      args,
      env ? { },
    }:
    {
      type = "local";
      inherit command args env;
    };

  # A remote server, which the agent reaches over HTTP.
  #
  # Remote servers authenticate out-of-band (OAuth, once per machine), so there
  # is no secret to inject and nothing to gate on. `env = { }` is not a
  # placeholder: it makes availability hold vacuously, so a remote server is
  # available on every host and no rule below needs a case for it.
  mkRemote =
    { url }:
    {
      type = "remote";
      inherit url;
      env = { };
    };

  # The servers named in `requested`, from `catalog`. A name the catalog does not
  # define aborts evaluation, the way an unknown skill name does.
  selectServers =
    catalog: requested:
    let
      unknown = lib.subtractLists (lib.attrNames catalog) requested;
    in
    if unknown != [ ] then
      throw ''
        profile: unknown MCP server(s): ${lib.concatStringsSep ", " unknown}.
        Defined in programs/agents/mcp: ${lib.concatStringsSep ", " (lib.attrNames catalog)}.
      ''
    else
      lib.getAttrs requested catalog;

  # The servers this host can run, with every secret name resolved to its path.
  #
  # A server whose secret the host does not declare is dropped silently, so a
  # setup listing it gets nothing at all rather than a server fed a placeholder
  # token. Availability is all-or-nothing: a server naming two secrets needs both.
  availableServers =
    secrets: servers:
    lib.mapAttrs (_: server: server // { env = provided secrets server.env; }) (
      lib.filterAttrs (_: server: lib.all (name: secrets ? ${name}) (lib.attrValues server.env)) servers
    );

  # Of `names` (variable -> secret name), the ones this host provides, each
  # resolved to its path. A missing secret drops only its own variable: a secret
  # file is handed out as a path, and the program reading it decides what its
  # absence means.
  provided =
    secrets: names:
    lib.mapAttrs (_: name: secrets.${name}) (lib.filterAttrs (_: name: secrets ? ${name}) names);

  check =
    let
      # Given: a host that declares two of the three secrets this catalog names.
      secrets = {
        figma-token = "/run/secrets/figma-token";
        shared-token = "/run/secrets/shared-token";
      };
      catalog = {
        figma = mkLocal {
          command = "npx";
          args = [ "figma-developer-mcp" ];
          env.FIGMA_API_KEY = "figma-token";
        };
        secretless = mkLocal {
          command = "node";
          args = [ "time-server" ];
        };
        twoSecrets = mkLocal {
          command = "node";
          args = [ "two-secret-server" ];
          env = {
            A_TOKEN = "shared-token";
            B_TOKEN = "undeclared-token";
          };
        };
        remote = mkRemote { url = "https://mcp.example.com/mcp"; };
      };
      available = availableServers secrets catalog;
      # When: a setup asks for servers by name.
      select = requested: availableServers secrets (selectServers catalog requested);
      names = lib.attrNames;
      throws = import ./throws.nix;
    in
    assert lib.assertMsg (
      names available == [
        "figma"
        "remote"
        "secretless"
      ]
    ) "mcp: a server is available only when every secret it names is declared";
    assert lib.assertMsg (
      available.figma.env == { FIGMA_API_KEY = "/run/secrets/figma-token"; }
    ) "mcp: an available server did not get its secret names resolved to paths";
    assert lib.assertMsg (
      available.secretless.env == { }
    ) "mcp: a server naming no secrets is not available with an empty env";
    assert lib.assertMsg (
      available ? remote
    ) "mcp: a remote server is not available on a host that declares none of its secrets";
    assert lib.assertMsg (select [ ] == { }) "mcp: asking for nothing gave servers";
    assert lib.assertMsg (
      names (select [
        "figma"
        "secretless"
      ]) == [
        "figma"
        "secretless"
      ]
    ) "mcp: asking for available servers did not give exactly those";
    assert lib.assertMsg (
      select [ "twoSecrets" ] == { }
    ) "mcp: a known but unavailable server was not dropped";
    assert lib.assertMsg (
      names (select [
        "remote"
        "twoSecrets"
      ]) == [ "remote" ]
    ) "mcp: an unavailable local server was kept beside a remote one";
    assert lib.assertMsg (throws (
      selectServers catalog [ "figmaa" ]
    )) "mcp: a server outside the catalog did not abort evaluation";
    assert lib.assertMsg (
      provided secrets {
        FIGMA_FILE = "figma-token";
        MISSING_FILE = "undeclared-token";
      } == {
        FIGMA_FILE = "/run/secrets/figma-token";
      }
    ) "mcp: a secret file was not resolved to its path, or a missing one was kept";
    pkgs.writeText "mcp-check" "";
in
{
  inherit
    mkLocal
    mkRemote
    selectServers
    availableServers
    provided
    check
    ;
}
