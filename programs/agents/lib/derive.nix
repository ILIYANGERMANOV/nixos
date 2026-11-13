# Derived roles, stage A (#351 section 8, plan #360): a role's capabilities,
# skills, operations and preloaded prose are the union of the profiles of the
# steps it runs, read from the flows' step table. Nothing here is written by
# hand per role; `roles/<name>/role.nix` keeps the identity.
#
#   steps(r)  = rows whose runner is r, plus the inline rows of the flow r
#               leads, the one named after it
#   ops(r)    = union of ops, plus spawn:<r'> per runner r' in r's flow
#   caps(r)   = union of tools, plus delegate when ops(r) holds a spawn
#   skills(r) = union of skills
#   prose(r)  = union of prose; for a split role, the prose every step needs
{
  pkgs,
  lib,
  # mkRole's capabilities, in the order a record lists them.
  capabilities,
}:

let
  # The roles whose preload is split from their steps' entry (stage A). Stage
  # C, every role, is #355.
  split = [
    "engineer"
    "review-lead"
  ];

  union = field: rows: lib.unique (lib.concatMap (row: row.${field}) rows);
  intersection =
    field: rows:
    lib.foldl' (kept: row: lib.filter (item: lib.elem item row.${field}) kept) (lib.head rows).${field}
      (lib.tail rows);
  isSpawn = lib.hasPrefix "spawn:";

  stepsOf =
    table: role:
    lib.attrValues (
      lib.filterAttrs (
        _: row: row.runner == role || (row.runner == "inline" && lib.elem role row.flows)
      ) table
    );

  # The roles a flow spawns, as ops.
  spawnsOf =
    table: flow:
    map (row: "spawn:${row.runner}") (
      lib.filter (row: row.runner != "inline" && lib.elem flow row.flows) (lib.attrValues table)
    );

  # role name -> { capabilities, skills, operations, prose }.
  derive =
    table: role:
    let
      rows = stepsOf table role;
      operations = lib.sort lib.lessThan (lib.unique (union "ops" rows ++ spawnsOf table role));
      tools = union "tools" rows ++ lib.optional (lib.any isSpawn operations) "delegate";
      prose = if lib.elem role split then intersection "prose" rows else union "prose" rows;
      # A split role's other prose would be entry prose, but `state next`
      # prints only a row's `entry` text: no prose file would reach it.
      unreached = lib.subtractLists prose (union "prose" rows);
    in
    if rows == [ ] then
      throw "role ${role}: no row of flows/steps.nix runs it; add a `flows = [ \"other\" ]` row"
    else if unreached != [ ] then
      throw "role ${role}: ${lib.concatStringsSep ", " unreached} is not prose every step needs, and state next prints no prose file"
    else
      {
        # In mkRole's order; an unknown tool is kept, for mkRole to refuse.
        capabilities =
          lib.filter (capability: lib.elem capability tools) capabilities
          ++ lib.subtractLists capabilities tools;
        skills = union "skills" rows;
        inherit operations prose;
      };

  # The laws of #360's Tests table over the real table and records.
  # `roles` are the records, `prose` maps a prose name to its fragment, and
  # `golden` holds today's records, each { capabilities skills operations prose }.
  check =
    {
      table,
      roles,
      prose,
      golden,
    }:
    let
      missing = needed: held: lib.subtractLists held needed;
      fragments = names: map (name: prose.${name}) names;

      needs =
        role: record:
        lib.concatMap (
          row:
          missing row.tools record.capabilities
          ++ missing row.skills record.skills
          ++ missing row.ops record.operations
          ++ missing (fragments row.prose) record.instructions
        ) (stepsOf table role);

      extras =
        role: record:
        let
          rows = stepsOf table role;
          operations = union "ops" rows ++ spawnsOf table role;
          own = lib.filter (
            fragment: lib.hasSuffix "/roles/${role}/role.md" (toString fragment.file)
          ) record.instructions;
        in
        missing record.capabilities (
          union "tools" rows ++ lib.optional (lib.any isSpawn record.operations) "delegate"
        )
        ++ missing record.skills (union "skills" rows)
        ++ missing record.operations operations
        ++ missing record.instructions (own ++ fragments (union "prose" rows));

      failing = law: lib.attrNames (lib.filterAttrs (role: record: law role record != [ ]) roles);
      sufficient = failing needs;
      lean = failing extras;
      drifted = lib.attrNames (
        lib.filterAttrs (role: _: derive table role != golden.${role} or null) roles
      );
    in
    assert lib.assertMsg (
      sufficient == [ ]
    ) "derived_role_holds_every_step_need: ${toString sufficient} lack what a step needs";
    assert lib.assertMsg (
      lean == [ ]
    ) "derived_role_holds_nothing_else: ${toString lean} hold what no step needs";
    assert lib.assertMsg (
      drifted == [ ] && lib.attrNames golden == lib.attrNames roles
    ) "derived_equals_recorded_golden: ${toString drifted} differ from roles/golden.nix";
    pkgs.writeText "derive-check" "";
in
{
  inherit derive check;
}
