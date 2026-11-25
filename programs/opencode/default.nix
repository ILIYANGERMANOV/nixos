# OpenCode, as two flavors (see flavor.nix):
#
# - opencode-kategory: the base and local profiles, for a person at a terminal;
# - opencode-kategory-headless: the same plus the headless profile, for a run
#   with nobody there, such as a CI job. Its lead answers every question
#   itself, and OpenCode's question tool is off.
{
  pkgs,
  lib ? pkgs.lib,
  opencode,
  agents,
  ...
}:

let
  mkFlavor = import ./flavor.nix {
    inherit
      pkgs
      lib
      opencode
      agents
      ;
  };

  localProfiles = [
    agents.profiles.base
    agents.profiles.local
  ];

  local = mkFlavor {
    name = "opencode-kategory";
    profiles = localProfiles;
  };

  headless = mkFlavor {
    name = "opencode-kategory-headless";
    profiles = localProfiles ++ [ agents.profiles.headless ];
    # Nobody is there to pick an answer. `run` already denies the tool in a
    # new session; this says so in the config, where the check sees it.
    permission.question = "deny";
  };
in
{
  inherit (local) kategory;
  kategoryHeadless = headless.kategory;

  # checks.opencode: the wrapper run offline against everything above.
  check = import ./check.nix {
    inherit pkgs lib;
    inherit (local) kategory;
    tiers = lib.mapAttrs (_: role: role.tier) agents.roles;
    inherit (local.profile) skills;
    # A role that may only read, rendered as the real ones are: none of them
    # is that narrow, as every one may run a shell.
    readOnlyRole =
      (local.renderRoles {
        read-only = agents.roles.reviewer // {
          name = "read-only";
          capabilities = [ "read" ];
        };
      } local.profile.instructions).read-only;
  };

  # checks.opencode-headless: the headless flavor runs a scripted model's
  # tool call to the end with nobody there. See check-headless.sh.
  checkHeadless =
    pkgs.runCommand "opencode-headless-check"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.python3
        ];
        env = {
          kategory = lib.getExe headless.kategory;
          scripted_model = "${./scripted-model.py}";
        };
      }
      ''
        bash ${./check-headless.sh}
        touch "$out"
      '';
}
