---
name: start-repo
description: Turn a repository on in the software factory - clone it if needed and start its Remote Control server, now and at every boot. Use when the person wants to start working in a repository, add one, or bring a stopped one back.
argument-hint: <repo name | git URL>
---

# Start a repository

1. Get the target from the arguments. If there is none, ask which repository.
2. A URL (contains `:` or `/`): run `factory-ctl start <url>`. Prefer SSH URLs;
   turn `https://github.com/owner/repo` into `git@github.com:owner/repo.git`,
   because the bot clones and pushes over SSH.
3. A bare name: run `factory-ctl start <name>`.
   - Exit 0: done.
   - Exit 3, not cloned: run `factory-ctl resolve <name>`.
     - One URL: ask the person to confirm `owner/repo` before cloning it.
     - Several: ask which, listing them as `owner/repo`.
     - None: say the bot cannot see a repository by that name and ask for the
       URL; the bot may need to be invited to it.
     Then run `factory-ctl start <url>`.
4. Starting is idempotent: an existing clone is kept and a running server is
   left alone, so rerunning is always safe.

Reply in one line, for example: `deslop is on. Open it from the Claude app.`
