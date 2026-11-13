# The flows' step table: `table` as written and checked, for lib/derive.nix,
# and `steps`, the JSON the kernel reads (#360 call 16): plain eval, no
# derivation is read back. The kernel gets the flows' `steps` only; `offFlow`
# is for the derivation.
#
# A step's runner is a sum: an `inline` step has no `lead`, a role's step
# must have one. Like lib/role.nix, anything unknown or missing throws.
{ pkgs, lib }:
let
  table = load (import ./steps.nix);

  profile = [
    "tools"
    "skills"
    "prose"
    "ops"
  ];
  stepFields = [
    "dom"
    "cod"
    "exit"
    "outcomes"
    "runner"
    "task"
    "flows"
  ]
  ++ profile;
  offFlowFields = [ "role" ] ++ profile;
  flowNames = [
    "engineer"
    "10x"
  ];

  # The fields a step must have: a role's step adds `lead`.
  stepShape = step: stepFields ++ lib.optional (step.runner or null != "inline") "lead";

  fieldProblems =
    fields: row:
    map (field: "unknown field ${field}") (lib.subtractLists fields (lib.attrNames row))
    ++ map (field: "missing field ${field}") (lib.subtractLists (lib.attrNames row) fields);

  stepProblems =
    step:
    fieldProblems (stepShape step) step
    ++ map (flow: "unknown flow ${flow}") (lib.subtractLists flowNames (step.flows or [ ]));

  load =
    written:
    let
      named =
        kind: problems: rows:
        lib.concatLists (
          lib.mapAttrsToList (name: row: map (problem: "${kind} ${name}: ${problem}") (problems row)) rows
        );
      found =
        fieldProblems [ "steps" "offFlow" ] written
        ++ named "step" stepProblems (written.steps or { })
        ++ named "offFlow" (fieldProblems offFlowFields) (written.offFlow or { });
    in
    if found != [ ] then throw "flows/steps.nix: ${lib.concatStringsSep "; " found}" else written;

  # Each way to break the runner sum, or a row, is refused.
  check =
    let
      inline = {
        dom = "Ctx";
        cod = "Ctx";
        exit = null;
        outcomes = [ "done" ];
        runner = "inline";
        task = "Do it.";
        tools = [ ];
        skills = [ ];
        prose = [ ];
        ops = [ ];
        flows = [ "engineer" ];
      };
      agent = inline // {
        runner = "researcher";
        lead = "Spawn one.";
      };
      offFlow = {
        role = "checker";
        tools = [ ];
        skills = [ ];
        prose = [ ];
        ops = [ ];
      };
      valid = {
        steps = { inherit inline agent; };
        offFlow.check = offFlow;
      };
      withStep =
        step:
        valid
        // {
          steps = valid.steps // {
            bad = step;
          };
        };
      rejected = written: !(builtins.tryEval (builtins.deepSeq (load written) null)).success;
    in
    assert lib.assertMsg (!rejected valid) "load refused a valid table";
    assert lib.assertMsg (rejected (
      withStep (inline // { lead = "Spawn one."; })
    )) "load accepted an inline step with a lead";
    assert lib.assertMsg (rejected (
      withStep (removeAttrs agent [ "lead" ])
    )) "load accepted a role's step without a lead";
    assert lib.assertMsg (rejected (
      withStep (removeAttrs inline [ "task" ])
    )) "load accepted a step without a task";
    assert lib.assertMsg (rejected (
      withStep (inline // { entry = "Do it."; })
    )) "load accepted an unknown step field";
    assert lib.assertMsg (rejected (
      withStep (inline // { flows = [ "other" ]; })
    )) "load accepted an unknown flow";
    assert lib.assertMsg (rejected (
      valid
      // {
        offFlow = valid.offFlow // {
          bad = offFlow // {
            runner = "checker";
          };
        };
      }
    )) "load accepted an unknown offFlow field";
    pkgs.writeText "flows-check" "";
in
{
  inherit table check;
  steps = pkgs.writeText "steps.json" (builtins.toJSON table.steps);
}
