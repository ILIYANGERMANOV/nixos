---
name: restart-repo
description: Restart a repository's Remote Control server in the software factory, to unstick a wedged server or apply a configuration deployed since it started. Use when a repository's server misbehaves or after a deploy that changed the agents' setup.
argument-hint: <repo name>
---

# Restart a repository

1. Get the name from the arguments. If there is none, run `factory-ctl status`
   and ask which one, offering the ones that are on or failed.
2. Run `factory-ctl restart <name>`.
   - Exit 0: done.
   - Exit 2, refused: show the live sessions and the worktrees with local work
     it printed, and ask whether to restart anyway - live sessions end. Only on
     a clear yes, run `factory-ctl restart --force <name>`.
   - "is off": offer to turn it on with the start-repo skill instead.

Reply in one line.
