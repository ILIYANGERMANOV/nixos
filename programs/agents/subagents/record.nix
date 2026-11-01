# mkAgent: one role as a harness-agnostic record. Each agent program renders it
# its own way; a field here that one harness cannot honour is that renderer's
# problem, and nothing here may name a harness.
#
# A renderer writes a record to a format that ignores what it does not know, so a
# typo here could quietly widen what the role may do. Anything unknown throws.
{
  lib,
  core,
  skillNames,
}:

let
  # name, description: what the role is, for whoever spawns it.
  # instructions: paths of the prose, in order. `core` goes in front of them.
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
    ++ map (skill: "${skill} is not in the skill catalog") (
      lib.subtractLists skillNames (record.skills or [ ])
    )
    ++ lib.optional (!lib.elem (record.tier or null) tiers) "unknown tier"
    ++ lib.optional (!lib.elem (record.effort or null) efforts) "unknown effort";
in
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
  throw "agent ${spec.name or "?"}: ${lib.concatStringsSep ", " found}"
else
  record
  // {
    instructions = [ core ] ++ spec.instructions;
  }
