# A guard over the prompt sources, not a transformer: it returns the files
# unchanged, or throws if one still holds a mode rule of its own. The Quality
# table in instructions/agent.md is the one place a mode changes a step, and
# only the engineer sets Size, so a skill or role that repeats a mode row, the
# old `, Trivial` suffix or a self-activation phrase has drifted from it.
{
  pkgs,
  lib,
  # The directories whose files may only read the table: skills and roles.
  roots,
  # Files under `roots` that may name the old forms: self-improve's analyzer
  # and its metrics explain transcripts written before the table.
  exempt,
}:

let
  phrases = [
    "| POC |"
    "| Balanced |"
    "| Max |"
    ", Trivial"
    "not Trivial"
    "unless your input says"
    "qualifies by the Trivial rule"
  ];

  modes =
    files:
    let
      found = lib.concatMap (
        file:
        map (phrase: "${toString file} holds `${phrase}`") (
          lib.filter (phrase: lib.hasInfix phrase (lib.fileContents file)) phrases
        )
      ) files;
    in
    if found == [ ] then
      files
    else
      throw "modes: a mode rule outside the Quality table: ${lib.concatStringsSep ", " found}";

  sources = lib.filter (file: !lib.any (dir: lib.hasPrefix (toString dir) (toString file)) exempt) (
    lib.concatMap lib.filesystem.listFilesRecursive roots
  );

  check =
    let
      clean = [ (builtins.toFile "clean.md" "Your row in the Quality table says how deep.\n") ];
      dirty = [
        (builtins.toFile "dirty.md" "| Mode | Refactor |\n|---|---|\n| POC | one quick pass |\n")
      ];
      suffix = [ (builtins.toFile "suffix.md" "Brief it `Quality: <mode>, Trivial`.\n") ];
      throws = import ../throws.nix;
    in
    assert lib.assertMsg (modes clean == clean) "modes: refused a file that only reads the table";
    assert lib.assertMsg (throws (modes dirty)) "modes: let a mode table row through";
    assert lib.assertMsg (throws (modes suffix)) "modes: let the old `, Trivial` suffix through";
    builtins.seq (modes sources) (pkgs.writeText "modes-check" "");
in
{
  inherit modes check;
}
