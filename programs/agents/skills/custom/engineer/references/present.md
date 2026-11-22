# Present

The `present` step composes the whole plan as one message, read on a phone,
and writes it to `<notes>/present.md`. It asks nothing: `confirm` sends that
message with the Confirm question as its final text. The user decides from it
alone, so it carries what they need and nothing else. The file tree and the
pseudo-code carry the most weight: give them the most care.

Write it in the style of the `pr-description` skill: follow its `## Style`
and `### Visuals` sections in `~/.claude/skills/pr-description/SKILL.md`.

## Layout

In this order:

1. **What & Why**: 3 bullets. The change, the problem it solves, the result.
2. **Flow**: a vertical text diagram of how it works, one line per step.
3. **Pseudo-code**: the core code, the data format it reads or writes, and
   the main loop or decision. Short, in the target language's idiom.
4. **Files**: a tree of the files the plan adds or changes, a short note per
   file. Mark new files `NEW`.
5. **What the refine passes changed**: the plan's `## Considered options`
   table, cut to its Pass, Finding and Taken? columns, each cell a few words.
   No pass ran: one line saying why.
6. **Collapsed**: `<details>` sections for Tests, Out of scope and Fuel.

Leave out what the user already settled and needs no reminder of: the
plan's file has it, and the PR body gets it.

## A breakdown (10x)

The plan is a breakdown of tasks: replace items 2 to 4 with one section per
task, in the plan's order: its goal, Fuel, its file tree, its pseudo-code
where its plan holds it, and any trade-off left to the user with its
options. Then the pre-flight table. Items 5 and 6 cover the whole breakdown.
