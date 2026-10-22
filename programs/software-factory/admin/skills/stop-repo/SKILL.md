---
name: stop-repo
description: Turn a repository off in the software factory - stop its Remote Control server and keep it from starting at boot. The clone and its worktrees are kept. Use when the person is done with a repository for now.
argument-hint: <repo name>
---

# Stop a repository

1. Get the name from the arguments. If there is none, run `factory-ctl status`
   and ask which repository to stop, offering the ones that are on.
2. The admin agent's own server is not a repository and cannot be stopped this
   way. If asked to stop "admin", say so.
3. Run `factory-ctl stop <name>`.
   - Exit 0: done.
   - Exit 2, refused: it printed the live sessions and the worktrees with
     uncommitted or unpushed work. Show that briefly and ask whether to stop
     anyway. Only on a clear yes, run `factory-ctl stop --force <name>`.
     Worktrees stay on disk either way; live sessions end.
4. Stopping an already stopped repository is a no-op.

Reply in one line, for example: `deslop is off and will stay off after reboots.`
