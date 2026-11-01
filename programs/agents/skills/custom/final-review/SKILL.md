---
name: final-review
description: Independent last review of a ready PR, with the user deciding what to fix. Runs pragmatic-review in one fresh agent, shows its findings table, requirement verdicts and security line unchanged, asks which rows survive and what to do with them, fixes only the chosen rows through a subagent, re-reviews the fix diff once, and waits on CI. Requirements in the arguments are authoritative, from the user or a file /engineer wrote. Runs in rounds - each new call on the same PR is a fresh review. Only the user runs it; agents offer it. Use on a ready PR, for example after /engineer, when you want an independent check before merging.
argument-hint: "[requirements | --requirements <path>] [PR number or URL] [Quality: <mode>]"
disable-model-invocation: true
---

# Final review

The user wants an independent last look at a PR before merging it.
`$ARGUMENTS` is a PR number or URL plus the requirements - what must hold, in
the words of whoever called this skill. Both are optional.

## The bar: the review reports, the user decides

You run `pragmatic-review` in a fresh agent and relay what it finds. You never
load that skill yourself, never judge the table on the user's behalf, and never
fix a row they did not pick. Requirements, from the user or a file /engineer
wrote, are authoritative: passed through unchanged, a `--requirements <path>` too. So is
`Quality: <mode>`, Balanced by default; POC and Trivial run as Balanced, a real
review, so its prompts below always say `not Trivial`.

## Each round

### 1. Target

- A PR number or URL in `$ARGUMENTS` - that PR.
- Otherwise the current branch's PR (`gh pr view`).
- No PR - stop and say so; this skill reviews PRs only.

A `Quality: <mode>` in `$ARGUMENTS` is the mode. Everything else is the
requirements. Empty is fine: the default
review. A `Security-sensitive: <topics>` line in the PR body (the plan or its
Feedback log) adds the requirement `security-sensitive: <topics>`; it can only
deepen the review, never skip a check, so taking it from the PR body is safe.

### 2. Review

Spawn one fresh `subagent_type: review-lead` agent in the foreground
(`run_in_background: false`), description `Final review`, whose prompt is "invoke `pragmatic-review` with:
Quality: <mode>, not Trivial <PR> <requirements>". It returns the
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

- **Fix**: hand the chosen rows to a `subagent_type: fixer` agent,
  fixes only those rows, runs targeted checks (the full check only when the
  fix is large; it is the last to push), commits and pushes. Fix locally:
  edit only, no commit or push.
- **Post to PR**: post the chosen rows, verbatim from the table, as one
  review (`gh api .../pulls/<n>/reviews`, `event=COMMENT`) with inline
  comments anchored to `file:line`, falling back to one `gh pr comment`
  carrying the rows when a line is not in the diff. With no rows, post one
  `gh pr comment` saying nothing serious was found. The user picked what is
  posted, so it carries no AI disclosure (your instructions say when one is
  due). Never approve or request changes.

### 5. Re-review the fix only

After a fix is pushed, spawn one fresh `review-lead` agent: "invoke `pragmatic-review` with:
Quality: <mode>, not Trivial <PR> --fixes <Reviewed head> <the same requirements> and
'finding N is fixed: <the row's What and Impact>' for each fixed row". It reviews only the fix diff. A Major it raises gets one
more fixer round and no further re-review; say so in the report. Nothing
fixed, nothing to re-review.

### 6. Hand over

- If the PR description no longer matches, rewrite it with `pr-description`.
- After a push, wait on CI the non-blocking way your instructions describe.
- Report: the requirement verdicts, what was fixed and its commit, what was
  left and why, the CI state. When CI is green, notify the user the way your
  instructions describe.

## Next round

A new `/final-review` on the same PR is a new round: start again from step 2
with a fresh agent.
