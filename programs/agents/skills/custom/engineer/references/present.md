# Present

The `present` step shows the whole plan as one message, read on a phone,
before the `confirm` question. The user decides from it alone, so it carries
what they need and nothing else. The file tree and the pseudo-code carry the
most weight: give them the most care.

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
5. **What the refine passes changed**: one table, `| Pass | Took | Left out |`,
   from the plan's `## Considered options`, each row a few words. No pass
   ran: one line saying why.
6. **Collapsed**: `<details>` sections for Tests, Out of scope and Fuel.
7. **The Confirm question** last, as the `confirm` step words it.

Leave out what the user already settled and needs no reminder of: the
plan's file has it, and the PR body gets it.
