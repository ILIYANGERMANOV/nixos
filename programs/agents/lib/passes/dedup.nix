# A guard over a folded profile, not a transformer: it returns the profile
# unchanged, or throws if it still holds a duplicate the monoid cannot see. A
# skill name twice would install two skills under one name, and one file at two
# layers is a distinct fragment each time, so its render would hold it twice.
{
  pkgs,
  lib,
  instructions,
}:

let
  dedup =
    profile:
    let
      files = map (fragment: fragment.file) (
        lib.unique (profile.instructions.forAll ++ profile.instructions.forLead)
      );
      found =
        map (skill: "skill ${skill}") (duplicates profile.skills)
        ++ map (file: "instruction file ${toString file}") (duplicates files);
    in
    if found == [ ] then
      profile
    else
      throw "dedup: the folded profile holds ${lib.concatStringsSep ", " found} more than once";

  duplicates = values: lib.unique (lib.filter (value: lib.count (v: v == value) values > 1) values);

  check =
    let
      file = "/a.md";
      clean = {
        skills = [ "a" ];
        instructions = instructions.mkInstructions {
          forAll = [
            (instructions.mkFragment {
              layer = "agent";
              inherit file;
            })
          ];
        };
      };
      throws = value: !(builtins.tryEval (builtins.deepSeq value value)).success;
    in
    assert lib.assertMsg (dedup clean == clean) "dedup: changed a profile with no duplicates";
    assert lib.assertMsg (throws (
      dedup (
        clean
        // {
          skills = [
            "a"
            "a"
          ];
        }
      )
    )) "dedup: let one skill name through twice";
    assert lib.assertMsg (throws (
      dedup (
        clean
        // {
          instructions = instructions.append clean.instructions (
            instructions.mkInstructions {
              forLead = [
                (instructions.mkFragment {
                  layer = "context";
                  inherit file;
                })
              ];
            }
          );
        }
      )
    )) "dedup: let one file through at two layers";
    pkgs.writeText "dedup-check" "";
in
{
  inherit dedup check;
}
