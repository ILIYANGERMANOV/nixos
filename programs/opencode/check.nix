# checks.opencode: opencode-kategory run offline, with HOME in the build dir,
# against what it promises. See check.sh.
{
  pkgs,
  lib,
  kategory,
  # The roles, by name, as records.
  roles,
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
      read_only_role = readOnlyRole;
      # name -> tier, null where the role inherits its spawner's model.
      tiers = builtins.toJSON (lib.mapAttrs (_: role: role.tier) roles);
      skills = builtins.toJSON skills;
    };
  }
  ''
    bash ${./check.sh}
    touch "$out"
  ''
