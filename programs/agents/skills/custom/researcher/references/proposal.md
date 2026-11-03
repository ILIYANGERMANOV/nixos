# Proposal mode

Your prompt names this file and a mode, `simplify` or `alternative`, with a
plan path, the research notes paths and `notes`, a directory under `/tmp`. It
replaces the researcher skill's Process, Notes and Hand-back. Its rules on
bounded reads, labels and data still hold, and so does its Budget for your
Quality.

## Both modes

- Keep the plan's goals and intent. Not naive: a proposal still meets every
  goal and every decision the user made.
- Research the industry standards and known solutions for the problem: formal
  standards, de facto practice, well-known prior art. Name each with a URL.
- Every claim about the repo has a `path:line`; every outside claim a URL.

## `simplify`

Revise the given plan to an equivalent that is simpler or follows a standard:
fewer moving parts, an existing helper or tool, a standard over a home-grown
format. The result is the revised plan.

## `alternative`

Write a different plan for the same goals and intent: another approach, not a
tweak of the given one. When no sound one exists, return the given plan
unchanged and say why: that is the identity, and the caller asks Yes or Adjust.

## Output

`<notes>/proposal-<mode>.md`: the plan in the given plan's shape, then:

```markdown
## Considered options
| Option | Trade-off | Standard |
|---|---|---|
| <the given plan> | <cost, benefit> | <URL or none> |
| <your proposal, or "identity: <why none>"> | <cost, benefit> | <URL> |
```

Hand back the file path, what changed and why in a few bullets, and each
option's trade-off, in about 250 words.
