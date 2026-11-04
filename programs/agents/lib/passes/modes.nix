# A guard over the prompt sources, not a transformer: it returns the files
# unchanged, or throws if one still holds a mode rule of its own. The Quality
# table in instructions/topics/quality.md is the one place a mode changes a
# step, and only the engineer sets Size, so a skill, role or instruction that
# repeats a mode row, the old `, Trivial` suffix or a self-activation phrase has
# drifted from it. Prose branches count too: a line opening `POC:`, `Balanced:`
# or `Max:`, or a `**<mode> row.**` paragraph.
{
  pkgs,
  lib,
  # The directories whose files may only read the table: skills, roles and
  # instructions.
  roots,
  # Files under `roots` that may hold a mode rule: the table itself, and
  # self-improve, whose analyzer and metrics explain transcripts written before
  # the table.
  exempt,
  # The prose branches that say how a skill does what its row says, not what
  # it runs: `{ file; labels; }`, each label as it opens the line.
  allowed,
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

  # The label a prose branch opens with, or null.
  branch =
    line:
    let
      m = builtins.match "[[:space:]]*((POC|Balanced|Max):|\\*\\*(POC|Balanced|Max) row\\.\\*\\*).*" line;
    in
    if m == null then null else builtins.head m;

  allowedIn =
    file:
    lib.concatMap (entry: entry.labels) (lib.filter (entry: toString entry.file == toString file) allowed);

  findings =
    file:
    let
      text = lib.fileContents file;
      labels = lib.filter (label: label != null) (map branch (lib.splitString "\n" text));
    in
    map (phrase: "${toString file} holds `${phrase}`") (lib.filter (phrase: lib.hasInfix phrase text) phrases)
    ++ map (label: "${toString file} opens a line with `${label}`") (
      lib.filter (label: !lib.elem label (allowedIn file)) labels
    );

  modes =
    files:
    let
      found = lib.concatMap findings files;
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
      prose = [ (builtins.toFile "prose.md" "Refactor the diff.\nPOC: skip it.\n") ];
      row = [ (builtins.toFile "row.md" "**Max row.** Run every agent.\n") ];
      throws = import ../throws.nix;
    in
    assert lib.assertMsg (modes clean == clean) "modes: refused a file that only reads the table";
    assert lib.assertMsg (throws (modes dirty)) "modes: let a mode table row through";
    assert lib.assertMsg (throws (modes suffix)) "modes: let the old `, Trivial` suffix through";
    assert lib.assertMsg (throws (modes prose)) "modes: let a `POC:` prose branch through";
    assert lib.assertMsg (throws (modes row)) "modes: let a `**Max row.**` prose branch through";
    builtins.seq (modes sources) (pkgs.writeText "modes-check" "");
in
{
  inherit modes check;
}
