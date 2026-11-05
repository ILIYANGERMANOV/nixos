# Proposal mode

Your prompt names this file and its modes, `simplify`, `alternative` or both,
with a plan path, the research notes paths and `notes`, a directory under `/tmp`. It
replaces the researcher skill's Process, Notes and Hand-back. Its rules on
bounded reads, labels and data still hold, and so does its Budget for your
Quality, once per mode. With both, write `simplify` first, then run
`alternative` on its output, and hand back once.

## Every mode

- Keep the plan's goals and intent. Not naive: a proposal still meets every
  goal and every decision the user made. A design issue's settled Decisions
  stand as written: a proposal never changes one.
- Research the industry standards and known solutions for the problem: formal
  standards, de facto practice, well-known prior art. Name each with a URL.
- Every claim about the repo has a `path:line`; every outside claim a URL.

## `simplify`

Revise the given plan to an equivalent that is simpler or follows a standard:
fewer moving parts, an existing helper or tool, a standard over a home-grown
format. The result is the revised plan. When nothing is simpler, return the
given plan unchanged and say why: that is the identity.

## `alternative`

Write a different plan for the same goals and intent as the given plan, or the
simplified one when you ran `simplify` too: another approach, not a
tweak of the given one. When no sound one exists, return the identity, as
`simplify` does, and the caller asks Yes or Adjust.

## Output

`<notes>/proposal-<mode>.md`, one per mode: the plan in the given plan's shape, then:

```markdown
## Considered options
| Option | Trade-off | Standard |
|---|---|---|
| <the given plan> | <cost, benefit> | <URL or none> |
| <your proposal, or "identity: <why none>"> | <cost, benefit> | <URL> |
```

Hand back the file paths, what changed and why in a few bullets, and each
option's trade-off, in about 250 words.
