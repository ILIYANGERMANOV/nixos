# Instructions as a monoid. A fragment is one prose file at one layer; an
# instructions value is two ordered sets of fragments: `forAll` reaches every
# agent, subagent roles included, and `forLead` only the agent leading a session.
#
# `append` concatenates each set and keeps the first occurrence, so `empty` is
# its identity and appending a value to itself changes nothing. The render sorts
# stably by layer, so the order values were appended in only matters within a
# layer.
{ pkgs, lib }:

let
  # Broadest first. Agent: what every agent gets. Context: where it runs (a
  # profile's prose). Role: what this agent is. Topic: one subject it needs.
  layers = [
    "agent"
    "context"
    "role"
    "topic"
  ];

  mkFragment =
    { layer, file }:
    if lib.elem layer layers then
      { inherit layer file; }
    else
      throw "instructions: unknown layer ${layer} for ${toString file}, expected one of ${toString layers}";

  mkInstructions =
    {
      forAll ? [ ],
      forLead ? [ ],
    }:
    {
      forAll = lib.unique forAll;
      forLead = lib.unique forLead;
    };

  empty = mkInstructions { };

  append =
    a: b:
    mkInstructions {
      forAll = a.forAll ++ b.forAll;
      forLead = a.forLead ++ b.forLead;
    };

  # The agent leading a session.
  renderLead = instructions: render (instructions.forAll ++ instructions.forLead);

  # A subagent role: `forAll`, then its own fragments (its prose and topics).
  renderRole = instructions: fragments: render (instructions.forAll ++ fragments);

  # The files of these fragments, in layer order. builtins.sort is stable.
  render =
    fragments:
    map (fragment: fragment.file) (
      builtins.sort (a: b: rank a.layer < rank b.layer) (lib.unique fragments)
    );

  rank = layer: lib.lists.findFirstIndex (l: l == layer) null layers;

  # Laws, over fragments at every layer with one duplicate across values.
  check =
    let
      at =
        layer: name:
        mkFragment {
          inherit layer;
          file = "/${name}.md";
        };
      a = mkInstructions {
        forAll = [ (at "topic" "t") ];
        forLead = [ (at "role" "r") ];
      };
      b = mkInstructions {
        forAll = [
          (at "agent" "a")
          (at "topic" "t")
        ];
      };
      c = mkInstructions { forLead = [ (at "context" "c") ]; };
      throws = value: !(builtins.tryEval (builtins.deepSeq value value)).success;
    in
    assert lib.assertMsg (append empty a == a) "instructions: empty is not a left identity";
    assert lib.assertMsg (append a empty == a) "instructions: empty is not a right identity";
    assert lib.assertMsg (
      append (append a b) c == append a (append b c)
    ) "instructions: append is not associative";
    assert lib.assertMsg (append a a == a) "instructions: appending a value to itself changed it";
    assert lib.assertMsg (
      (append a b).forAll == [
        (at "topic" "t")
        (at "agent" "a")
      ]
    ) "instructions: append did not keep the first occurrence";
    assert lib.assertMsg (
      renderLead (append (append a b) c) == [
        "/a.md"
        "/c.md"
        "/r.md"
        "/t.md"
      ]
    ) "instructions: the lead render is not sorted by layer";
    assert lib.assertMsg (
      renderRole b [
        (at "role" "r2")
        (at "role" "r1")
      ] == [
        "/a.md"
        "/r2.md"
        "/r1.md"
        "/t.md"
      ]
    ) "instructions: the role render is not a stable sort by layer";
    assert lib.assertMsg (throws (
      at "chapter" "x"
    )) "instructions: mkFragment accepted an unknown layer";
    pkgs.writeText "instructions-check" "";
in
{
  inherit
    mkFragment
    mkInstructions
    empty
    append
    renderLead
    renderRole
    check
    ;
}
