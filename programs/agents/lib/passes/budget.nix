# The size budget every agent program shares, in bytes of what the repository
# controls: the lead's instructions, and `loads`, what one kind of agent reads for
# its work - its role's instructions, the SKILL.md of each skill it preloads and
# the references it reads - plus the repository's own instructions. A vendor
# measures what only its format adds, appends those lines, and holds both to
# `ceilings` and its own.
#
# A rise in budget.json is the visible diff that says a change costs every agent
# more start-up context.
{
  pkgs,
  lib,
  # name -> skill directory, the catalog.
  skills,
  roles,
  renderRole,
}:

let
  # A role's references, beyond the skills it preloads.
  reads =
    let
      review = "${skills.pragmatic-review}/references";
    in
    {
      reviewer = [
        "${review}/bar.md"
        "${review}/blockers.md"
      ];
      review-lead = [
        "${review}/first-pass.md"
        "${review}/bar.md"
      ];
    };

  # Keyed by the records, so a new role has no ceiling in budget.json and fails
  # the check until it gets one.
  roleLoads =
    instructions:
    lib.mapAttrs (
      name: role:
      renderRole instructions role.instructions
      ++ map (skill: "${skills.${skill}}/SKILL.md") role.skills
      ++ reads.${name} or [ ]
    ) roles;

  # `<ceiling key> <subject> <bytes>` lines.
  #   leads            - subject -> a lead's rendered instructions file
  #   roleInstructions - the instructions roles are rendered with: a role counts
  #                      at its largest
  #   repoInstructions - the repository's own instructions file
  sizes =
    {
      leads,
      roleInstructions,
      repoInstructions,
    }:
    pkgs.runCommand "agent-budget-sizes" { } ''
      ${lib.concatStrings (
        lib.mapAttrsToList (subject: file: ''
          echo "instructions ${subject} $(wc -c <${file})" >>"$out"
        '') leads
      )}
      ${lib.concatStrings (
        lib.mapAttrsToList (name: files: ''
          cat ${lib.concatMapStringsSep " " (file: lib.escapeShellArg "${file}") files} >load
          echo "${name} - $(wc -c <load)" >>"$out"
        '') (roleLoads roleInstructions // { repo-instructions = [ repoInstructions ]; })
      )}
    '';

in
{
  inherit sizes;
  ceilings = ../../budget.json;
}
