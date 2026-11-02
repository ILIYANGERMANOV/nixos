# mkRole: one role as a harness-agnostic record. Each agent program renders it
# its own way; a field here that one harness cannot honour is that renderer's
# problem, and nothing here may name a harness.
#
# A renderer writes a record to a format that ignores what it does not know, so a
# typo here could quietly widen what the role may do. Anything unknown throws.
#
# discover: a roles directory holds one folder per role, `<name>/role.nix`, and
# `shared/` for prose more than one role reads. Every other folder is a role.
{
  pkgs,
  lib,
  skillNames,
}:

let
  # name, description: what the role is, for whoever spawns it.
  # instructions: fragments of its prose and topics (lib/instructions.nix). A
  # renderer puts the instructions every agent gets in front of them.
  # capabilities: what it may do, from `capabilities` below.
  # skills: catalog skills it starts with loaded.
  # tier, effort: null inherits from whoever spawns it.
  fields = [
    "name"
    "description"
    "instructions"
    "capabilities"
    "skills"
    "tier"
    "effort"
  ];
  capabilities = [
    "read"
    "edit"
    "shell"
    "web"
    "delegate"
  ];
  tiers = [
    null
    "small"
    "medium"
    "large"
  ];
  efforts = [
    null
    "low"
    "medium"
    "high"
  ];

  problems =
    record:
    map (field: "unknown field ${field}") (lib.subtractLists fields (lib.attrNames record))
    ++ map (field: "missing field ${field}") (lib.subtractLists (lib.attrNames record) fields)
    ++ map (capability: "unknown capability ${capability}") (
      lib.subtractLists capabilities (record.capabilities or [ ])
    )
    ++ map (skill: "${skill} is not in the skill catalog") (lib.subtractLists skillNames record.skills)
    ++ lib.optional (!lib.elem record.tier tiers) "unknown tier"
    ++ lib.optional (!lib.elem record.effort efforts) "unknown effort";

  mkRole =
    spec:
    let
      record = {
        skills = [ ];
        tier = null;
        effort = null;
      }
      // spec;
      found = problems record;
    in
    if found != [ ] then
      throw "role ${spec.name or "?"}: ${lib.concatStringsSep ", " found}"
    else
      record;

  # Role name -> its role.nix.
  discover =
    dir:
    lib.mapAttrs (name: _: dir + "/${name}/role.nix") (
      lib.filterAttrs (name: type: type == "directory" && name != "shared") (builtins.readDir dir)
    );

  # Each way to break a record is refused, and discovery finds the one role in a
  # fixture that also holds shared/ and a plain file.
  check =
    let
      valid = {
        name = "valid";
        description = "A valid role.";
        instructions = [ ];
        capabilities = [ "read" ];
      };
      rejected = spec: !(builtins.tryEval (mkRole spec)).success;
    in
    assert lib.assertMsg (!rejected valid) "mkRole refused a valid record";
    assert lib.assertMsg (rejected (valid // { tolls = [ ]; })) "mkRole accepted a misspelled field";
    assert lib.assertMsg (rejected (
      removeAttrs valid [ "description" ]
    )) "mkRole accepted a missing field";
    assert lib.assertMsg (rejected (
      valid // { capabilities = [ "reed" ]; }
    )) "mkRole accepted an unknown capability";
    assert lib.assertMsg (rejected (
      valid // { skills = [ "no-such-skill" ]; }
    )) "mkRole accepted an unknown skill";
    assert lib.assertMsg (rejected (valid // { tier = "huge"; })) "mkRole accepted an unknown tier";
    assert lib.assertMsg (rejected (valid // { effort = "hgih"; })) "mkRole accepted an unknown effort";
    assert lib.assertMsg (
      discover ./fixtures/roles == { alpha = ./fixtures/roles/alpha/role.nix; }
    ) "discover did not find exactly the role folders";
    pkgs.writeText "role-check" "";
in
{
  inherit mkRole discover check;
}
