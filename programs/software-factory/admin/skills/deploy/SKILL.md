---
name: deploy
description: Deploy the latest main of the nixos repository to this software factory server, or roll back to the previous system. Deploys run only for commits whose CI passed, and roll back by themselves if the box stops being reachable. Use when the person asks to deploy, update the server, or undo a deploy.
argument-hint: "[rollback]"
---

# Deploy or roll back

## Deploy

1. Run `factory-ctl status`. If repositories have live sessions, say how many
   and mention that a deploy keeps them running; offer the terminate-sessions
   skill only if the person wants a clean slate. Do not block on it.
2. Run `factory-ctl deploy`. It waits for the GitHub workflow, which refuses
   unless CI passed on main's tip; on failure it prints why and a link.
3. The server picks the deployment up within a minute and builds it, which can
   take several minutes. Check `factory-ctl status` every minute or two until
   the last deploy shows `success` or `failure` for the new commit, then report
   it in one line.

Servers are not restarted by a deploy. If it changed the agents' setup, offer
the restart-repo skill for the repositories that need it.

## Roll back

On "rollback" or "undo the deploy": confirm once, then run `factory-ctl
rollback` and check `factory-ctl status` for the result. Only the previous
generation is kept, so a second rollback goes forward again.
