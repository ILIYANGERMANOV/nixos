---
name: terminate-sessions
description: End live Claude Code sessions in the software factory's repositories while their Remote Control servers keep running. Use when agents are stuck, using too much memory, or before a deploy. Never ends the admin agent's own session.
argument-hint: "[repo name]"
---

# Terminate sessions

1. With a repository name, end that repository's sessions; without one, end the
   sessions of every repository. If the person's wording is unclear about
   which, ask.
2. Run `factory-ctl terminate [name]`.
   - Exit 0: done, or there were none.
   - Exit 2, refused: some sessions sit in worktrees with uncommitted or
     unpushed work, so an agent is probably mid-task. Show the list and ask.
     Only on a clear yes, run `factory-ctl terminate --force [name]`. The
     worktrees and their work stay on disk.

Reply in one line, for example: `Ended 3 sessions; all servers still on.`
