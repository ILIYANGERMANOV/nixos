# Hooks: programs an agent runs when a session starts and around its tool
# calls, declared once for every agent. A hook module is a file setting
# `hooks.<name> = { on; tools; command; order; }`; a profile lists the files.
#
# Typed with the module system, so a misspelled field, an unknown event or tool
# is an eval error. Every option is `uniq`, and so is each hook: a plain
# submodule would merge two declarations of one name silently, concatenating
# their tools or one adding fields the other left out.
#
# A backend registers one entry per event, its adapter hands the event to
# agent_hook.py's dispatcher, and the dispatcher runs that event's hooks in the
# order `eval` gives. So the order, the threading of rewritten input and what
# a failing hook does are the same on every agent.
{
  pkgs,
  lib,
  # The packages a hook module may take as module arguments, such as `state`
  # for its own hooks' commands.
  packages ? { },
}:

let
  inherit (lib) mkOption types;

  # The names an event, tool and session start take, shared with agent_hook.py.
  vocabulary = lib.importJSON ./vocabulary.json;

  hook = {
    options = {
      on = mkOption {
        type = types.uniq (types.enum vocabulary.events);
        description = "The event the hook runs at.";
      };
      tools = mkOption {
        type = types.uniq (types.nullOr (types.nonEmptyListOf (types.enum vocabulary.tools)));
        default = null;
        description = "The tools whose calls it sees; null for every tool. None at sessionStart.";
      };
      command = mkOption {
        type = types.uniq (types.nonEmptyListOf types.str);
        description = "The argv it runs, reading the event on stdin (agent_hook.py).";
      };
      order = mkOption {
        type = types.uniq types.int;
        default = 0;
        description = "Lower runs first within its event; a tie runs by name.";
      };
    };
  };

  # Module arguments beside the packages, such as a host's `secretFiles`, and
  # hook modules -> event -> [{ name, tools, command }], in the order they run.
  # Every event is present, an event with no hooks as [].
  eval =
    args: modules:
    let
      declared =
        (lib.evalModules {
          specialArgs = packages // args;
          modules = [
            {
              options.hooks = mkOption {
                type = types.attrsOf (types.uniq (types.submodule hook));
                default = { };
              };
            }
          ]
          ++ modules;
        }).config.hooks;
      toolsAtStart = lib.attrNames (
        lib.filterAttrs (_: h: h.on == "sessionStart" && h.tools != null) declared
      );
      ordered = lib.sort (a: b: if a.order == b.order then a.name < b.name else a.order < b.order) (
        lib.mapAttrsToList (name: h: h // { inherit name; }) declared
      );
    in
    if toolsAtStart != [ ] then
      throw "hooks: ${toString toolsAtStart} name tools, but run at sessionStart, which calls none"
    else
      lib.genAttrs vocabulary.events (
        event: map (h: { inherit (h) name tools command; }) (lib.filter (h: h.on == event) ordered)
      );

  # What the dispatcher reads: `eval`'s output as JSON.
  manifest = events: pkgs.writeText "agent-hooks.json" (builtins.toJSON events);

  # agent_hook.py as a Python library, for a backend's adapter and the hooks.
  module = pkgs.python3Packages.toPythonModule (
    pkgs.runCommand "agent-hook" { } ''
      site=$out/${pkgs.python3.sitePackages}
      install -Dm644 ${./agent_hook.py} $site/agent_hook.py
      # A hook pays for compiling on every tool call, and the store cannot hold
      # a cache written at run time. Unchecked: a store path never changes.
      ${pkgs.python3.interpreter} -m compileall -q --invalidation-mode unchecked-hash $site
    ''
  );

  check =
    let
      throws = import ../lib/throws.nix;
      declare = name: spec: { hooks.${name} = spec; };
      # The fixtures' specs, declared again under other names.
      inherit ((import ./fixtures/resume.nix).hooks) resume;
      inherit ((import ./fixtures/spawn.nix).hooks) spawn;
      names = map (h: h.name);
      # The guards on a host with one secret file, and on one with none.
      secretFile = "/run/secrets/qa-key";
      guarded = eval { secretFiles.QA_KEY_FILE = secretFile; } [ ./guards/hooks.nix ];
      unguarded = eval { secretFiles = { }; } [ ./guards/hooks.nix ];
      events = eval { } [
        ./fixtures/resume.nix
        ./fixtures/resume.nix
        (declare "b" (spawn // { order = 1; }))
        (declare "c" spawn)
        (declare "a" (spawn // { order = 1; }))
      ];
    in
    assert lib.assertMsg (
      map (h: h.name) events.beforeTool == [
        "c"
        "a"
        "b"
      ]
    ) "hooks: an event's hooks did not run by order, then by name";
    assert lib.assertMsg (
      events.sessionStart == [
        {
          name = "resume";
          tools = null;
          command = [ "resume" ];
        }
      ]
    ) "hooks: one hook file listed twice did not count once";
    assert lib.assertMsg (events.afterTool == [ ]) "hooks: an event with no hooks is not []";
    assert lib.assertMsg (throws (
      eval { } [
        (declare "a" spawn)
        (declare "a" spawn)
      ]
    )) "hooks: one name declared twice did not throw";
    assert lib.assertMsg (throws (
      eval { } [
        (declare "a" resume)
        (declare "a" { order = 1; })
      ]
    )) "hooks: a second declaration setting only other fields of one name did not throw";
    assert lib.assertMsg (throws (
      eval { } [
        (declare "a" (spawn // { on = "beforeLunch"; }))
      ]
    )) "hooks: an unknown event did not throw";
    assert lib.assertMsg (throws (
      eval { } [
        (declare "a" (spawn // { tools = [ "teleport" ]; }))
      ]
    )) "hooks: an unknown tool did not throw";
    assert lib.assertMsg (throws (
      eval { } [
        (declare "a" (spawn // { tool = [ "shell" ]; }))
      ]
    )) "hooks: a misspelled field did not throw";
    assert lib.assertMsg (throws (
      eval { } [
        (declare "a" (resume // { tools = [ "shell" ]; }))
      ]
    )) "hooks: a sessionStart hook naming tools did not throw";
    assert lib.assertMsg (
      names guarded.beforeTool == [
        "secret-guard"
        "read-guard"
        "wait-guard"
      ]
    ) "hooks: the guards do not run secret, read, then wait";
    assert lib.assertMsg (
      lib.last (lib.head guarded.beforeTool).command == builtins.toJSON {
        paths = [ secretFile ];
        vars = [ "QA_KEY_FILE" ];
      }
    ) "hooks: the secret guard is not handed the host's secret files";
    assert lib.assertMsg (
      names unguarded.beforeTool == [
        "read-guard"
        "wait-guard"
      ]
    ) "hooks: a host with no secret file got a secret guard";
    assert lib.assertMsg (
      map (h: { inherit (h) name tools; }) guarded.afterTool == [
        {
          name = "context-guard";
          tools = null;
        }
      ]
    ) "hooks: the context guard does not see every tool";
    pkgs.writeText "hooks-check" "";
in
{
  inherit
    vocabulary
    eval
    manifest
    module
    check
    ;
}
