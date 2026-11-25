# A catalog SKILL.md read at evaluation: its frontmatter lines and its body.
# The skills check (programs/agents/skills) holds every SKILL.md to an opening
# `---` line and a closing one, so the split needs no fallback.
{ lib }:

let
  # The lines after the opening `---`, split at the closing one.
  split =
    file:
    let
      lines = lib.drop 1 (lib.splitString "\n" (lib.fileContents file));
      close = lib.lists.findFirstIndex (line: line == "---") null lines;
    in
    {
      frontmatter = lib.take close lines;
      body = lib.concatLines (lib.drop (close + 1) lines);
    };
in
{
  # Whether the skill keeps the model from invoking it, leaving only its
  # command (`disable-model-invocation: true`).
  manualOnly = file: lib.elem "disable-model-invocation: true" (split file).frontmatter;

  body = file: (split file).body;
}
