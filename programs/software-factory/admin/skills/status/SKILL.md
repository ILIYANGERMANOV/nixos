---
name: status
description: Show the software factory at a glance - every repository's server (on, off, failed), live sessions, worktrees with local work, the last deploy, rollback or GC, and whether the deploy token is about to expire. Use when the person asks what is running or how the box is doing.
---

# Status

Run `factory-ctl status` and present it for a phone:

- One compact table: repository, state, sessions. Mention local work only where
  there is some.
- `on*` means running but not set to start at boot; `failed` or `activating`
  need attention - say so and offer the restart-repo skill.
- Then one line for the last root operation, and the token warning verbatim if
  there is one.

Do not add anything the command did not report.
