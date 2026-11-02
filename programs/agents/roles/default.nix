# The subagent roles every host installs: one folder each, `<name>/role.nix`
# and its prose, found by lib/role.nix's `discover`. Adding a role is adding its
# folder. A role.nix is a function from the arguments below to a record; see
# lib/role.nix for the fields. Each agent program renders the records its own
# way.
#
# A role reads only its own folder and `shared/`, which holds prose more than
# one role reads (the ladder rule in deslop/rules/architecture.yaml).
{
  lib,
  mkRole,
  discover,
  mkFragment,
  topics,
}:

let
  # A role's prose, from its own folder or shared/.
  role =
    file:
    mkFragment {
      layer = "role";
      inherit file;
    };
in
lib.mapAttrs (name: file: mkRole (import file { inherit role topics; } // { inherit name; })) (
  discover ./.
)
