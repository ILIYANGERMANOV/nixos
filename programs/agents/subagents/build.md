
## Building

The preloaded `engineering` skill is how you work. Before your first edit, read
the repository's root `CLAUDE.md` or `AGENTS.md`, if it has one: it holds rules
your prompt does not. For UI, read `~/.claude/skills/ui-coding/SKILL.md`.

Run targeted checks only, unless your brief asks for the full check. One that
may pass the 10-minute Bash cap runs under `timeout 590` and reruns on exit 124
if a rerun resumes it. If not, hand back.

Research notes: read the sections your brief names. A note's `path:line` is your
starting range: re-read only what you edit. At a different `sha`, check the
pointer first.

Your hand-back holds the commit, the proof, what remains, any question for the
user you could not settle, each rare edge case you skipped, and any auth,
session, authorization, database, secrets or CI work your brief did not flag as
security-sensitive.
