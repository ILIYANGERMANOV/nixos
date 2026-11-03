# When a changed file reaches a running Claude Code, for each path link writes.
# `When` is one of:
#   Live        - the running session picks it up
#   NextSession - a session started after the change reads it
#   Restart     - only a new process sees it: the factory's long-running
#                 Remote Control servers must be restarted
{ lib }:

let
  home = import ../codegen/home.nix { inherit lib; };

  whens = [
    "Live"
    "NextSession"
    "Restart"
  ];

  applies = {
    # Claude Code watches the skill directories.
    ${home.skillsDir} = "Live";
    # Hooks are snapshotted when a session starts.
    ${home.settings} = "NextSession";
    ${home.instructions} = "NextSession";
    ${home.agentsDir} = "NextSession";
    ".claude.json mcpServers" = "NextSession";
    # The wrapper's PATH and secrets are the process environment, set at exec.
    environment = "Restart";
  };
in
lib.mapAttrs (
  path: when:
  assert lib.assertMsg (lib.elem when whens)
    "applies: ${path} has When ${when}, not one of ${toString whens}";
  when
) applies
