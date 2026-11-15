# The subagent roles every host installs: one folder each, `<name>/role.nix`
# and its prose, found by lib/role.nix's `discover`. Adding a role is adding its
# folder and a row of flows/steps.nix it runs. A role.nix holds the identity,
# the description, tier, effort and its own role.md; `derived` (lib/derive.nix)
# gives the rest from the steps it runs. See lib/role.nix for the fields. Each
# agent program renders the records its own way.
#
# A role reads only its own folder and `shared/`, which holds prose more than
# one role reads (the ladder rule in deslop/rules/architecture.yaml).
{
  lib,
  mkRole,
  discover,
  mkFragment,
  # role name -> { capabilities, skills, operations, prose }.
  derived,
  # prose name -> fragment.
  prose,
}:

let
  # A role's prose, from its own folder.
  role =
    file:
    mkFragment {
      layer = "role";
      inherit file;
    };
in
lib.mapAttrs (
  name: file:
  let
    identity = import file { inherit role; };
    from = derived name;
  in
  mkRole (
    identity
    // {
      inherit name;
      inherit (from) capabilities skills operations;
      instructions =
        identity.instructions
        ++ map (name: prose.${name} or (throw "flows/steps.nix: no prose named ${name}")) from.prose;
    }
  )
) (discover ./.)
