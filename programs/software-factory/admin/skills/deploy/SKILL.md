---
name: deploy
description: Deploy the latest main of the nixos repository to this software factory server, or roll back to the previous system. Deploys run only for commits whose CI passed, roll back by themselves if the box stops being reachable, and restart every running repository server so it gets the new setup. Use when the person asks to deploy, update the server, or undo a deploy.
argument-hint: "[rollback]"
---

# Deploy or roll back

## Deploy

1. Run `factory-ctl status`. If repositories have live sessions, say how many
   and that step 4 ends them. Do not block on it.
2. Check CI on main's tip before deploying:
   - Get the sha with `gh api repos/ILIYANGERMANOV/nixos/commits/main --jq
     .sha`, then its Check run with `gh run list --repo
     ILIYANGERMANOV/nixos --workflow check.yml --commit <sha> --json
     databaseId,status,conclusion,url`.
   - Still running: run `gh run watch <id> --repo ILIYANGERMANOV/nixos
     --exit-status` in the background (`run_in_background`), with no sleep
     or polling loop, and go on when it ends.
   - Failed: report the failure with the run's link and stop. Exception:
     when the only failed job is `tech` (see `gh run view <id> --repo
     ILIYANGERMANOV/nixos --json jobs`), deploy anyway; it does not gate
     deploys.
   - Passed: run `factory-ctl deploy`. It waits for the GitHub workflow,
     which refuses unless CI passed on main's tip; on failure it prints why
     and a link.
3. The server picks the deployment up within a minute and builds it, which can
   take several minutes. Check `factory-ctl status` every minute or two until
   the last deploy shows `success` or `failure` for the new commit.
4. On `success`, run `factory-ctl restart --force <name>` for every repository
   `factory-ctl status` shows as `on`, so each server runs the new skills and
   setup. The deploy itself restarts no server. Skip this step when the person
   said not to restart; restart only the ones they named, if they named any.
   Never restart the admin agent.
5. Report the deploy and the restarted servers in one line, naming any session
   the restarts ended.

## Roll back

On "rollback" or "undo the deploy": confirm once, then run `factory-ctl
rollback` and check `factory-ctl status` for the result. On success, restart
the servers as in step 4 of Deploy. Only the previous generation is kept, so a
second rollback goes forward again.
