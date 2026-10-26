---
name: final-review
description: Independent last review of a ready PR, with the user deciding what to fix. Runs pragmatic-review in one fresh agent, shows its findings table, requirement verdicts and security line unchanged, asks which rows survive and what to do with them, fixes only the chosen rows through a subagent, re-reviews the fix diff once, and waits on CI. Requirements in the arguments are the user's own and authoritative. Runs in rounds - each new call on the same PR is a fresh review. Use on a ready PR, for example after /engineer, when you want an independent check before merging.
disable-model-invocation: true
argument-hint: "[requirements] [PR number or URL]"
---

# Final review

The user wants an independent last look at a PR before merging it.
`$ARGUMENTS` is a PR number or URL plus their requirements - what must hold,
in their words. Both are optional.

## The bar: the review reports, the user decides

You run `pragmatic-review` in a fresh agent and relay what it finds. You never
load that skill yourself, never judge the table on the user's behalf, and never
fix a row they did not pick. Requirements are the user's own: authoritative,
passed through unchanged.

## Each round

### 1. Target

- A PR number or URL in `$ARGUMENTS` - that PR.
- Otherwise the current branch's PR (`gh pr view`).
- No PR - stop and say so; this skill reviews PRs only.

Everything else in `$ARGUMENTS` is the requirements. Empty is fine: the default
review.

### 2. Review

Spawn one fresh agent in the foreground (`run_in_background: false`) whose
prompt is "invoke `pragmatic-review` with: <PR> <requirements>". It returns the
findings table, the requirement verdicts, a `Security:` line, the verdict and
`Reviewed head: <sha>`. Record the head and the verdicts.

### 3. Show, then ask

Relay the table, the verdicts, the security line and the verdict to the user
unchanged. Then run the review's two pickers yourself with `AskUserQuestion`:

1. Which rows survive - `multiSelect`, grouped by severity, every Major
   recommended, at most four rows per question. Skip it when nothing survived.
2. What to do - one `multiSelect` question: **Fix + commit & push**, **Fix
   locally**, **Post to PR**.

### 4. Act

- **Fix**: hand the chosen rows to a fixer subagent that follows `engineering`,
  fixes only those rows, runs the narrowest checks while iterating and the
  repo's full check once, commits and pushes. Fix locally: no push.
- **Post to PR**: post the chosen rows, verbatim from the table, as one
  `gh pr review --comment`. Never approve or request changes.

### 5. Re-review the fix only

After a fix is pushed, spawn one fresh agent: "invoke `pragmatic-review` with:
<PR> --fixes <Reviewed head> <the same requirements> and 'finding N is fixed'
for each fixed row". It reviews only the fix diff. A Major it raises gets one
more fixer round and no further re-review; say so in the report. Nothing
fixed, nothing to re-review.

### 6. Hand over

- If the PR description no longer matches, rewrite it with `pr-description`.
- After a push, wait on CI the non-blocking way your instructions describe:
  `add_repo`, then `subscribe_pr_activity`; if refused, `gh pr checks <n>
  --watch` as a background Bash command. Never sleep, never poll.
- Report: the requirement verdicts, what was fixed and its commit, what was
  left and why, the CI state. When CI is green, `PushNotification`:
  `<repo>: PR #<n> final review done, CI green`.

## Next round

A new `/final-review` on the same PR is a new round: start again from step 2
with a fresh agent.
