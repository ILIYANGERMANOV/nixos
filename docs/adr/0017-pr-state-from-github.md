# PR state comes from GitHub, and a run is bound to its branch

Amends ADR 0016. The `pr` hook read `gh pr create` and `gh pr ready` out of the
lead's shell commands. It missed a PR made any other way (the web, another
agent, a command it could not lex) and took a PR body that mentions
`gh pr ready` for the command. Design: #341.

## Decisions

- **Read GitHub, record into the log.** `state next`, `state show` and every
  state hook first run `gh pr view --json url,baseRefName,headRefName,isDraft,state`
  and append only the event the step waits for: `drafted` at DraftPlan for an
  open PR, `ready` at PR for a PR that is no draft. Anything else appends
  nothing, so a sync twice is a sync once. The log stays the one replayable
  record (ADR 0014): a pure derive from GitHub would replay differently once
  the PR changes.
- **By URL once drafted.** Before `drafted` the read is the current branch's
  PR; after it, the recorded URL, so another branch's PR is never read.
- **Offline is not a failure.** No `gh`, a timeout or an error: the log is used
  as it is, and the output says `PR sync skipped - <why>`. `state record
  drafted|ready` by hand stays for that case and for delegated runs.
- **The `pr` hook and its shell lexer are gone.** The hooks left are resume,
  spawn, handback and asked, so the read is a few `gh` calls a session.
- **A run is bound to a branch.** `drafted` carries the PR's head branch. The
  hooks go silent, cheapest check first, when the log does not parse, the run
  is Done, HEAD is on another branch (no `gh` call), or the PR is merged or
  closed. Before `drafted` a run has no branch and the hooks behave as before.
  `state show` names the reason.

## Consequences

- A log whose `drafted` line has no `branch`, written before this ADR, does not
  parse: its hooks are silent and `state show` says to repair or delete the
  line. Logs live in `/tmp` and are not migrated.
- The `state` wrappers put a packaged `gh` after the session's PATH, so the
  `gh` the agent is logged in with is the one read.
