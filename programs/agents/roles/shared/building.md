
## Building

The preloaded `engineering` skill is how you work. Before your first edit, read
the repository's root `CLAUDE.md` or `AGENTS.md`, if it has one: it holds rules
your prompt does not. For UI, read `~/.claude/skills/ui-coding/SKILL.md`.

Edit code with Read and Edit, never `sed -i`: a shell edit fails silently or
hits the wrong match.

Run targeted checks only, unless your brief asks for the full check, in the
foreground: never start your own check in the background and poll it.

Read the branch diff in your prompt's `Diff:` folder, else `ctx diff <base>`
or `ctx delta`: `index`, then ranges, never `git diff`.

Research notes: read only the sections your brief names, found with
`rg -n '^#'`, never the whole note. A note's `path:line` is your
starting range: re-read only what you edit. At a different `sha`, check the
pointer first.

Your hand-back holds the commit, the proof, what remains, any question for the
user you could not settle, each rare edge case you skipped, and any auth,
session, authorization, database, secrets or CI work your brief did not flag as
security-sensitive.
