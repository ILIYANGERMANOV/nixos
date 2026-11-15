# Derived roles, stage A (#351 section 8, plan #360): a role's capabilities,
# skills, operations and preloaded prose are the union of the profiles of the
# steps it runs, read from the flows' step table. Nothing here is written by
# hand per role; `roles/<name>/role.nix` keeps the identity. A row is a step,
# or an `offFlow` entry, run by its `role`.
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
  # The roles whose preload is split from their steps' task (stage A). Stage
  # C, every role, is #355.
  split = [
    "engineer"
    "review-lead"
  ];

  # role name -> { capabilities, skills, operations, prose }.
  derive =
    table: role:
    let
      rows = stepsOf table role;
      operations = operationsOf table role;
      tools = toolsOf rows operations;
      prose = if lib.elem role split then intersection "prose" rows else union "prose" rows;
      # A split role's other prose would be task prose, but `state next`
      # prints only a step's `lead` and `task` text: no prose file would reach it.
      unreached = lib.subtractLists prose (union "prose" rows);
    in
    if rows == [ ] then
      throw "role ${role}: no row of flows/steps.nix runs it; add a step or an `offFlow` entry"
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

      # Recomputed from the rows, not through derive's helpers, so a bug in
      # them cannot hide here.
      extras =
        role: record:
        let
          rows = stepsOf table role;
          field = name: lib.concatMap (row: row.${name}) rows;
          spawns = map (row: "spawn:${row.runner}") (
            lib.filter (row: row.runner != "inline" && lib.elem role row.flows) (rowsOf table)
          );
          operations = field "ops" ++ spawns;
          tools = field "tools" ++ lib.optional (lib.any (lib.hasPrefix "spawn:") operations) "delegate";
          own = lib.filter (
            fragment: lib.hasSuffix "/roles/${role}/role.md" (toString fragment.file)
          ) record.instructions;
        in
        missing record.capabilities tools
        ++ missing record.skills (field "skills")
        ++ missing record.operations operations
        ++ missing record.instructions (own ++ fragments (field "prose"));

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

  stepsOf =
    table: role:
    lib.filter (row: row.runner == role || (row.runner == "inline" && lib.elem role row.flows)) (
      rowsOf table
    );

  # Every row as a step: an `offFlow` entry is run by its `role`, in no flow.
  rowsOf =
    table:
    lib.attrValues table.steps
    ++ map (
      entry:
      removeAttrs entry [ "role" ]
      // {
        runner = entry.role;
        flows = [ ];
      }
    ) (lib.attrValues table.offFlow);

  operationsOf =
    table: role:
    lib.sort lib.lessThan (lib.unique (union "ops" (stepsOf table role) ++ spawnsOf table role));

  # The roles a flow spawns, as ops.
  spawnsOf =
    table: flow:
    map (row: "spawn:${row.runner}") (
      lib.filter (row: row.runner != "inline" && lib.elem flow row.flows) (rowsOf table)
    );

  toolsOf =
    rows: operations: union "tools" rows ++ lib.optional (lib.any isSpawn operations) "delegate";
  isSpawn = lib.hasPrefix "spawn:";

  union = field: rows: lib.unique (lib.concatMap (row: row.${field}) rows);
  intersection =
    field: rows:
    lib.foldl' (kept: row: lib.filter (item: lib.elem item row.${field}) kept) (lib.head rows).${field}
      (lib.tail rows);
in
{
  inherit derive check;
}
