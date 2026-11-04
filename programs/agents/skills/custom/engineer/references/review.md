# The review loop

Steps 7 and 8, and step 10's CI fix. You drive the loop: a fresh review-lead
per round, a fixer between rounds. The cap is your Quality row's Re-reviews,
and the skill's stuck guard ends any round that makes no progress.

```
7 first review --rows--> 8 rounds left: fixer, --fixes review --rows--> 8 ...
  no rows chosen, at any round: step 9
  rows at the cap: final small fix, no review after it, then step 9
  plan wrong, at any round: blocker triage, no fixer
```

## Round 1: the first review (step 7)

1. Write the requirements once per plan to `requirements.md` in the skill's
   notes directory. A re-plan rewrites it, and its round 2 starts a fresh
   `-fixes` copy. They are the
   acceptance criteria plus what must hold where you are least sure of the
   implementation. The plan's decisions and out-of-scope list go with them as
   assumptions, in your words, so a deliberately skipped edge case is not
   raised. A `Security-sensitive:` line adds the requirement
   `security-sensitive: <topics>`. Every round gets `--requirements <path>`,
   never a list. /final-review gets this original file.
2. A PR that changes a skill gets a dry run, in parallel with round 1: a fresh
   `subagent_type: reviewer` agent reads the changed `SKILL.md` from the
   branch, not the installed copy, follows it step by step on a realistic
   task, with no push or other outside effect, and reports each step it could
   not follow or that misled it. Its findings join round 1's rows, when your
   Quality row's Skill dry run says so.
3. A fresh `subagent_type: review-lead` agent, prompt "invoke
   `pragmatic-review` with: Quality: <mode> <arguments>", plus the review-lead
   line in `blockers.md`. Never load that skill yourself.
4. Record its `Reviewed head` and requirement verdicts in the progress file.

## Picking rows

You answer the pickers by acting on the table yourself. Never reply to the
review agent with an action. Choose the rows worth fixing. Every surviving
house-rule row is fixed, or the reason for leaving it goes in the PR body.
When your Quality row fixes only blockers (security, irreversible damage,
broken code), every other row goes in `## Follow-ups`. No row chosen ends the loop: step 9.

A return that starts `NEEDS_DECISION plan wrong`: fix no row, security
included. Log its rows in the progress file and triage the line. The
re-plan's fresh round 1 finds them again.

## Rounds 2 and on (step 8)

Cap reached: the chosen rows go to the final small fix only. Rounds left:

1. A `subagent_type: fixer` agent gets the chosen rows, commits and pushes.
2. Copy the requirements file once beside it, with `fixes` for
   `requirements` in its name (`<task>-fixes.md` under a brief). Every round
   appends "finding N is fixed: <the row's What and Impact>" to that one copy
   for each row fixed.
3. A fresh review-lead invokes `pragmatic-review` with
   `--fixes <the previous round's Reviewed head>` and the copy. A requirement
   it answers "unchanged" keeps its latest verdict.
4. A fix your Quality row's Full review of a fix to names gets a first review
   of the whole branch instead, as round 1 does. It counts as a round.
5. Record the round, its `Reviewed head`, its chosen rows and its verdicts.
   Check the stuck guard, then pick rows again.

## Final small fix

After the last allowed review, in every mode: one fixer fixes what is safe and
small, and nothing reviews it. Security rows are always fixed, and blockers
only when your Quality row says so, as Picking rows says. Every other surviving house-rule row, Major row or
Not met verdict you do not fix goes in `## Follow-ups`, with the reason. Size decides fix or record, never drop. A row
that blocks the feature is a blocker: triage it.

## CI fix (step 10)

A CI failure goes to a fixer. Log the failing check and the head SHA in the
progress file and check the stuck guard. Rounds left: a `--fixes` review of that fix, as
in step 8, and step 8's loop on its rows. Rows at the cap: the final small fix.
Then back to the CI wait in step 10, never to step 9. Cap reached: straight
back to the CI wait. A fixer rewrites the PR body only if the fix changed what
it says. Notify only on ready.
