# Build-time tests for the ~/.claude.json MCP shape, the secret file guard, the
# hooks' settings and load/applies.nix, wired into `nix flake check` (and therefore `just check` in
# CI) as `checks.claude-code`. Which servers a host gets is programs/agents' logic and
# is tested in `checks.agents`; here the servers are the records it hands over,
# secrets already resolved to paths.
{
  pkgs,
  lib ? pkgs.lib,
}:

let
  inherit (lib.generators) toPretty;

  mcp = import ./codegen/mcp.nix { inherit lib; };

  # Given: servers as programs/agents hands them over for one host.
  figma = {
    type = "local";
    command = "npx";
    args = [ "figma-developer-mcp" ];
    env.FIGMA_API_KEY = "/run/secrets/figma-token";
  };
  secretless = {
    type = "local";
    command = "node";
    args = [ "time-server" ];
    env = { };
  };
  remote = {
    type = "remote";
    url = "https://mcp.example.com/mcp";
    env = { };
  };

  secretGuard = import ./hooks/secret-guard/secret-guard.nix { inherit pkgs; };

  # Given: a flavor's own settings, already holding a deny rule and a Bash hook.
  inherit
    (import ./codegen/settings.nix {
      inherit lib secretGuard;
      statusline = throw "the secret file guard sets no status line";
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

  hookSettings = import ./codegen/hooks.nix {
    inherit lib;
    sources = [
      "startup"
      "resume"
      "compact"
    ];
  };
  adapter = {
    type = "command";
    command = "agent-hook-claude tools.json manifest.json";
  };
  declared = name: tools: {
    inherit name tools;
    command = [ name ];
  };
  # Given: a folded profile's hooks, as agents.fold hands them over.
  profileHooks = {
    sessionStart = [ (declared "resume" null) ];
    beforeTool = [
      (declared "spawn" [ "delegate" ])
      (declared "pr" [
        "shell"
        "delegate"
      ])
    ];
    afterTool = [ ];
  };
  # When: the flavor runs them.
  hooked = hookSettings.withHooks adapter profileHooks flavorSettings;
  # A copy of programs/agents/lib/throws.nix: a program reaches another only
  # through its entry point (deslop programs-are-isolated), and one line is not
  # worth exposing from agents' default.nix.
  throws = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

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
          command = "node";
          args = [ "time-server" ];
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
          commands = [ "${secretGuard.bin}/bin/claude-secret-guard" ];
        }
      ];
    }
    {
      name = "a secret file leaves the flavor's other settings as they are";
      actual = guarded.model;
      expected = "opus";
    }
    {
      name = "hooks add one adapter entry per event they use, after the flavor's own, matched on their tools' union";
      actual = hooked.hooks;
      expected = {
        PreToolUse = flavorSettings.hooks.PreToolUse ++ [
          {
            matcher = "Agent|Bash";
            hooks = [ adapter ];
          }
        ];
        SessionStart = [
          {
            matcher = "startup|resume|compact";
            hooks = [ adapter ];
          }
        ];
      };
    }
    {
      name = "a hook with no tools has its event match every Claude tool, those with no vendor-free name too";
      actual =
        (hookSettings.withHooks adapter {
          afterTool = [
            (declared "shell" [ "shell" ])
            (declared "context" null)
          ];
        } { }).hooks.PostToolUse;
      expected = [ { hooks = [ adapter ]; } ];
    }
    {
      name = "hooks leave the flavor's other settings as they are";
      actual = removeAttrs hooked [ "hooks" ];
      expected = removeAttrs flavorSettings [ "hooks" ];
    }
    {
      name = "a profile with no hooks keeps its settings unchanged";
      actual = hookSettings.withHooks adapter {
        sessionStart = [ ];
        beforeTool = [ ];
        afterTool = [ ];
      } flavorSettings;
      expected = flavorSettings;
    }
    {
      name = "a hook tool with no Claude tool throws";
      actual = throws (
        hookSettings.withHooks adapter { beforeTool = [ (declared "x" [ "teleport" ]) ]; } { }
      );
      expected = true;
    }
    {
      name = "a hook event with no Claude event throws";
      actual = throws (hookSettings.withHooks adapter { beforeLunch = [ (declared "x" null) ]; } { });
      expected = true;
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
# applies.nix asserts its own cases when forced.
builtins.deepSeq (import ./load/applies.nix { inherit lib; }) pkgs.runCommand "claude-code-check"
  { }
  ''
    status=0

    ${lib.concatMapStringsSep "\n" report cases}

    if [ "$status" -ne 0 ]; then
      echo "claude-code: the MCP shape, the secret file guard or the hooks' settings are wrong" >&2
      exit 1
    fi

    touch "$out"
  ''
