# Profiles as a monoid. A profile is the vendor-free part of one setup: the
# skills it adds, its instructions (lib/instructions.nix), its MCP servers, the
# programs on its PATH and its secret files. Profiles are small
# deltas that never import each other; whoever selects them lists them and folds
# them with `append`.
#
# `append` merges field by field, so `empty` is its identity: lists union keeping
# the first occurrence, instructions use their own `append`, and keyed sets
# union where one key with two different values is an eval error, never
# last-writer-wins.
#
# A selector writes a profile to a format that ignores what it does not know, so
# a misspelled field would quietly drop what it holds. Anything unknown throws.
{
  pkgs,
  lib,
  instructions,
  skillNames,
  # MCP server names -> name -> server, from the catalog; throws on an unknown
  # name. lib/mcp.nix's selectServers bound to programs/agents/mcp.
  selectServers,
  serverNames,
}:

let
  mkProfile =
    spec:
    let
      unknown = lib.subtractLists (lib.attrNames fields) (lib.attrNames spec);
      profile =
        empty
        // spec
        // {
          skills = lib.unique (spec.skills or [ ]);
          mcp = selectServers (spec.mcp or [ ]);
        };
      unknownSkills = lib.subtractLists skillNames profile.skills;
    in
    if unknown != [ ] then
      throw "profile: unknown field(s) ${toString unknown}"
    else if unknownSkills != [ ] then
      throw "profile: ${toString unknownSkills} not in the skill catalog"
    else
      profile;

  empty = {
    skills = [ ];
    instructions = instructions.empty;
    mcp = { };
    runtime = [ ];
    secretFiles = { };
  };

  append = a: b: lib.mapAttrs (field: combine: combine a.${field} b.${field}) fields;

  fold = lib.foldl' append empty;

  # How each field combines. skills: catalog skill names. instructions: a value
  # of lib/instructions.nix. mcp: server name -> server, written as a list of
  # names. runtime: packages put on PATH. secretFiles: variable -> secret name,
  # for a program that reads the file itself.
  fields = {
    skills = union;
    instructions = instructions.append;
    mcp = merge;
    runtime = union;
    secretFiles = merge;
  };

  # Lists: concatenated, keeping the first occurrence.
  union = a: b: lib.unique (a ++ b);

  # Keyed sets: one key may only hold one value.
  merge = import ./merge.nix { inherit lib; } (a: b: a == b) (
    conflicts:
    "profile: ${lib.concatMapStringsSep ", " (c: c.key) conflicts} set to two different values"
  );

  # Laws, over profiles sharing a skill and a fragment, plus the throws.
  check =
    let
      at =
        layer: name:
        instructions.mkFragment {
          inherit layer;
          file = "/${name}.md";
        };
      skill = builtins.elemAt skillNames;
      server = builtins.elemAt serverNames;
      a = mkProfile {
        skills = [
          (skill 0)
          (skill 1)
        ];
        instructions = instructions.mkInstructions { forAll = [ (at "agent" "a") ]; };
        mcp = [ (server 0) ];
        secretFiles.A_FILE = "a-secret";
      };
      b = mkProfile {
        skills = [
          (skill 1)
          (skill 2)
        ];
        instructions = instructions.mkInstructions { forLead = [ (at "context" "b") ]; };
        mcp = [
          (server 0)
          (server 1)
        ];
      };
      c = mkProfile {
        skills = [ (skill 0) ];
        instructions = instructions.mkInstructions { forAll = [ (at "agent" "a") ]; };
      };
      throws = import ./throws.nix;
    in
    assert lib.assertMsg (append empty a == a) "profile: empty is not a left identity";
    assert lib.assertMsg (append a empty == a) "profile: empty is not a right identity";
    assert lib.assertMsg (
      append (append a b) c == append a (append b c)
    ) "profile: append is not associative";
    assert lib.assertMsg (
      fold [
        a
        b
        c
      ] == append (append a b) c
    ) "profile: fold is not append";
    assert lib.assertMsg (
      (append a b).skills == [
        (skill 0)
        (skill 1)
        (skill 2)
      ]
    ) "profile: append did not union the skills keeping the first occurrence";
    assert lib.assertMsg (
      lib.attrNames (append a b).mcp == lib.sort lib.lessThan [
        (server 0)
        (server 1)
      ]
    ) "profile: append did not merge the MCP servers";
    assert lib.assertMsg (throws (
      append a (mkProfile {
        secretFiles.A_FILE = "another-secret";
      })
    )) "profile: one secret file variable bound to two secrets did not throw";
    assert lib.assertMsg (
      merge { x = 1; } { x = 1; } == { x = 1; }
    ) "profile: one key set to one value twice threw";
    assert lib.assertMsg (throws (
      merge { x = 1; } { x = 2; }
    )) "profile: one key set to two values did not throw";
    assert lib.assertMsg (throws (mkProfile {
      skils = [ ];
    })) "profile: mkProfile accepted a misspelled field";
    assert lib.assertMsg (throws (mkProfile {
      skills = [ "no-such-skill" ];
    })) "profile: mkProfile accepted an unknown skill";
    assert lib.assertMsg (throws (mkProfile {
      mcp = [ "no-such-server" ];
    })) "profile: mkProfile accepted an unknown MCP server";
    pkgs.writeText "profile-check" "";
in
{
  inherit
    mkProfile
    empty
    append
    fold
    check
    ;
}
