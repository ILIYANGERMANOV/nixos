# Present

The `present` step composes the whole plan as one message, read on a phone,
and writes it to `<notes>/present.md`. It asks nothing: `confirm` sends that
message with the Confirm question as its final text. The user decides from it
alone, so it carries what they need and nothing else. The Slices and the
file tree carry the most weight: give them the most care.

Write it as "Writing for people" in your instructions says.

## Layout

In this order:

1. **What & Why**: 3 bullets. The change, the problem it solves, the result.
2. **Decisions**: a table of every decision the user made, `| Topic |
   Decision |`, so they can check the plan holds all they asked.
3. **Flow**: a vertical text diagram of how it works, one line per step.
4. **Slices**: one entry per implementer slice, in order. Each shows only its
   most important changes as small snippets: code, or the new prose text for
   a prose change. No boilerplate: no wiring, codecs, test plumbing or
   renames. Prose changes are never skipped.
5. **Files**: a tree of the files the plan adds or changes, a short note per
   file. Mark new files `NEW`.
6. **What the refine passes changed**: the plan's `## Considered options`
   table, cut to its Pass, Finding and Taken? columns, each cell a few words.
   No pass ran: one line saying why.
7. **Collapsed**: `<details>` sections for Tests, Out of scope and Fuel.

## A breakdown (10x)

The plan is a breakdown of tasks: replace items 3 to 5 with one section per
task, in the plan's order: its goal, Fuel, its file tree, its Slices, and any
trade-off left to the user with its options. Then the pre-flight table.
Items 2, 6 and 7 cover the whole breakdown.
