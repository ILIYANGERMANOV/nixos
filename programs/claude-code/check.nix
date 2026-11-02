# Build-time tests for the ~/.claude.json MCP shape and the secret file guard,
# wired into `nix flake check` (and therefore `just check` in CI) as
# `checks.claude-code`. Which servers a host gets is programs/agents' logic and
# is tested in `checks.agents`; here the servers are the records it hands over,
# secrets already resolved to paths.
{
  pkgs,
  lib ? pkgs.lib,
}:

let
  inherit (lib.generators) toPretty;

  mcp = import ./mcp.nix { inherit lib; };

  # Given: servers as programs/agents hands them over for one host.
  figma = {
    type = "local";
    command = "npx";
    args = [ "figma-developer-mcp" ];
    env.FIGMA_API_KEY = "/run/secrets/figma-token";
  };
  secretless = {
    type = "local";
    command = "uvx";
    args = [ "mcp-server-time" ];
    env = { };
  };
  remote = {
    type = "remote";
    url = "https://mcp.example.com/mcp";
    env = { };
  };

  # Given: a flavor's own settings, already holding a deny rule and a Bash hook.
  inherit
    (import ./lib.nix {
      inherit pkgs lib;
      claude-code = throw "the secret file guard builds no wrapper";
      mkSkillFarm = throw "the secret file guard builds no skills";
      fold = throw "the secret file guard folds no profiles";
      renderLead = throw "the secret file guard builds no instructions";
    })
    withSecretFileGuard
    ;
  flavorSettings = {
    model = "opus";
    permissions.deny = [ "Read(./.env)" ];
    hooks.PreToolUse = [
      {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "own-hook";
          }
        ];
      }
    ];
  };
  # When: the flavor is handed the secret file this host declares.
  guarded = withSecretFileGuard { FIGMA_TOKEN_FILE = "/run/secrets/figma-token"; } flavorSettings;

  cases = [
    {
      name = "a server with a secret is written as an env var reference, never a path";
      actual = mcp.mkMcpStructure { inherit figma; };
      expected = {
        figma = {
          type = "stdio";
          command = "npx";
          args = [ "figma-developer-mcp" ];
          env.FIGMA_API_KEY = "\${FIGMA_API_KEY}";
        };
      };
    }
    {
      name = "a server with no secrets is written with an empty env";
      actual = mcp.mkMcpStructure { inherit secretless; };
      expected = {
        secretless = {
          type = "stdio";
          command = "uvx";
          args = [ "mcp-server-time" ];
          env = { };
        };
      };
    }
    {
      name = "a remote server is written as a url, with no env and no command";
      actual = mcp.mkMcpStructure { inherit remote; };
      expected = {
        remote = {
          type = "http";
          url = "https://mcp.example.com/mcp";
        };
      };
    }
    {
      name = "a secret file's directory, its sops-nix .d and their macOS spellings are denied after the flavor's own rules";
      actual = guarded.permissions.deny;
      expected = [
        "Read(./.env)"
        "Read(//run/secrets/**)"
        "Read(//run/secrets.d/**)"
        "Read(//private/var/run/secrets/**)"
        "Read(//private/var/run/secrets.d/**)"
      ];
    }
    {
      name = "a secret file adds a Bash guard hook after the flavor's own hooks";
      actual = map (entry: {
        inherit (entry) matcher;
        commands = map (hook: lib.head (lib.splitString " " hook.command)) entry.hooks;
      }) guarded.hooks.PreToolUse;
      expected = [
        {
          matcher = "Bash";
          commands = [ "own-hook" ];
        }
        {
          matcher = "Bash";
          commands = [
            "${(import ./hooks/secret-guard/secret-guard.nix { inherit pkgs; }).bin}/bin/claude-secret-guard"
          ];
        }
      ];
    }
    {
      name = "a secret file leaves the flavor's other settings as they are";
      actual = guarded.model;
      expected = "opus";
    }
    {
      name = "a flavor with no secret file available keeps its settings unchanged";
      actual = withSecretFileGuard { } flavorSettings;
      expected = flavorSettings;
    }
  ];

  # Then: every case is reported, so one failure does not hide the rest.
  report =
    {
      name,
      actual,
      expected,
    }:
    if actual == expected then
      ''printf '  ✓ %s\n' ${lib.escapeShellArg name}''
    else
      ''
        printf '  ✗ %s\n' ${lib.escapeShellArg name} >&2
        printf '      expected: %s\n' ${lib.escapeShellArg (toPretty { } expected)} >&2
        printf '      actual:   %s\n' ${lib.escapeShellArg (toPretty { } actual)} >&2
        status=1
      '';
in
pkgs.runCommand "claude-code-check" { } ''
  status=0

  ${lib.concatMapStringsSep "\n" report cases}

  if [ "$status" -ne 0 ]; then
    echo "claude-code: the MCP shape or the secret file guard is wrong" >&2
    exit 1
  fi

  touch "$out"
''
