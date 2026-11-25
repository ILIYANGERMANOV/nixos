# checks.opencode: opencode-kategory run offline, with HOME in the build dir,
# against what it promises. See check.sh.
{
  pkgs,
  lib,
  kategory,
  # name -> tier, null where the role inherits its spawner's model.
  tiers,
  # The profile's skill names.
  skills,
  # A rendered role that may only read.
  readOnlyRole,
}:

pkgs.runCommand "opencode-check"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.curl
    ];
    env = {
      kategory = lib.getExe kategory;
      plugin = "${kategory.configDir}/plugin/kategory.js";
      read_only_role = readOnlyRole;
      tiers = builtins.toJSON tiers;
      skills = builtins.toJSON skills;
    };
  }
  ''
    bash ${./check.sh}
    touch "$out"
  ''
