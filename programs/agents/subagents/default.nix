# The subagent roles every host installs, one record each. Adding a role is one
# entry in `roles`, plus its prose; see record.nix for the fields. Each agent
# program renders them its own way.
{
  pkgs,
  lib ? pkgs.lib,
  skillNames,
  core,
  trivial,
}:

let
  mkAgent = import ./record.nix { inherit lib core skillNames; };

  roles = {
    researcher = {
      description = "Read-only research on one topic. Answers listed questions with bounded reads, writes a notes file and hands back a ranked file:line index. Changes nothing else.";
      instructions = [ ./researcher.md ];
      capabilities = [
        "read"
        "shell"
        "web"
      ];
      skills = [ "researcher" ];
      effort = "medium";
    };

    implementer = {
      description = "Implements one slice of a plan and commits. Splits a large slice across fresh implementers.";
      instructions = [
        ./implementer.md
        ./build.md
      ];
      capabilities = [
        "read"
        "edit"
        "shell"
        "delegate"
      ];
      skills = [ "engineering" ];
    };

    fixer = {
      description = "Fixes the review rows, failing check or rebase its brief names, and commits. Spawns nobody.";
      instructions = [
        ./fixer.md
        ./build.md
      ];
      capabilities = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "engineering" ];
    };

    # Spawns the `reviewer`s. It needs the Trivial rule: its check reads it.
    review-lead = {
      description = "Runs one pass of pragmatic-review: aims reviewer agents at a diff, judges what they bring back and reports. Changes no code.";
      instructions = [
        trivial
        ./review-lead.md
      ];
      capabilities = [
        "read"
        "shell"
        "delegate"
      ];
      skills = [ "pragmatic-review" ];
    };

    reviewer = {
      description = "One review agent under a review-lead: reads a diff against its brief and returns findings. Changes nothing.";
      instructions = [ ./reviewer.md ];
      capabilities = [
        "read"
        "shell"
      ];
    };
  };

  all = lib.mapAttrs (name: role: mkAgent (role // { inherit name; })) roles;

  valid = {
    name = "valid";
    description = "A valid role.";
    instructions = [ ];
    capabilities = [ "read" ];
  };
  rejected = spec: !(builtins.tryEval (mkAgent spec)).success;
in
{
  inherit all;

  # Every record evaluates, and each way to break one is refused.
  check =
    assert lib.assertMsg (!rejected valid) "mkAgent refused a valid record";
    assert lib.assertMsg (rejected (valid // { tolls = [ ]; })) "mkAgent accepted a misspelled field";
    assert lib.assertMsg (rejected (
      removeAttrs valid [ "description" ]
    )) "mkAgent accepted a missing field";
    assert lib.assertMsg (rejected (
      valid // { capabilities = [ "reed" ]; }
    )) "mkAgent accepted an unknown capability";
    assert lib.assertMsg (rejected (
      valid // { skills = [ "no-such-skill" ]; }
    )) "mkAgent accepted an unknown skill";
    assert lib.assertMsg (rejected (valid // { tier = "huge"; })) "mkAgent accepted an unknown tier";
    assert lib.assertMsg (rejected (
      valid // { effort = "hgih"; }
    )) "mkAgent accepted an unknown effort";
    builtins.deepSeq all (pkgs.writeText "subagents-check" "");
}
