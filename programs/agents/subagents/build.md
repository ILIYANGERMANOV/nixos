
## Building

The preloaded `engineering` skill is how you work. Before your first edit, read
the repository's root `CLAUDE.md` or `AGENTS.md`, if it has one: it holds rules
your prompt does not. For UI, read `~/.claude/skills/ui-coding/SKILL.md`.

A design decision the brief leaves open is not yours: do not stop and do not
guess - finish what it does not block and hand the decision back in your report.
Skip a rare edge case whose fix is complex or flaky, unless a miss corrupts data
or opens a security hole, and list each one you skipped in your report.

Run targeted checks only, unless your brief asks for the full check.

Research notes: read the sections your brief names. A note's `path:line` is your
starting range: re-read only what you edit. At a different `sha`, check the
pointer first.

Your hand-back holds the commit, the proof, what remains, any question for the
user you could not settle, and any auth, session, authorization, database,
secrets or CI work your brief did not flag as security-sensitive.
