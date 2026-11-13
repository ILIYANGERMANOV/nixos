# The review loop

The Review block and Ship's CI fix. You drive the loop: a fresh review-lead
per round, a fixer between rounds. Your Quality row's Re-reviews count the
rounds after the first; the stuck guard ends the loop early. Never load
`pragmatic-review` yourself.

## Requirements

Write the requirements once per plan, as `requirements.md` in the notes
directory, or use your brief's requirements file. They are the acceptance
criteria plus what must hold where you are least sure of the implementation.
Each of the plan's decisions is a requirement too, met only when the diff
follows it. The out-of-scope list goes with them as assumptions, in your
words, so a deliberately skipped edge case is not raised. A
`Security-sensitive:` line adds the requirement `security-sensitive: <topics>`.
/final-review gets this original file.

## Each round

The review-lead's prompt: `state brief review-lead`, then "invoke
`pragmatic-review` with: `--requirements <path> <PR> Quality: <mode>`", plus
`Size: Trivial` when set. A round after the first adds `--fixes <sha>`, the
last return's `Reviewed head`, and its requirements are a copy with a
"finding N is fixed: <What and Impact>" line per fixed row. A diff that
changes a skill gets your Quality row's Skill dry run in round 1: a fresh
`subagent_type: reviewer` agent walks the skill on a toy task.

## Picking rows

You answer the pickers by acting on the table yourself. Never reply to the
review agent with an action. Choose the rows worth fixing. Every surviving
house-rule row is fixed, or the reason for leaving it goes in the PR body.
When your Quality row fixes only blockers (security, irreversible damage,
broken code), every other row goes in `## Follow-ups`. A Not met verdict
never does: `Not met always` below. `pick.loop` sends the chosen rows to a
fixer, then a `--fixes` review; `pick.final`, with no row chosen or no round
left, ends the loop at the final fixer. Record every requirement's verdict.

A return that starts `NEEDS_DECISION plan wrong` is a question: fix and
record no row, security included. A re-plan's round 1 finds the rows again.

## Final fixer

The loop's one exit, in every mode. One fixer gets R0 and the last review's
chosen rows, and nothing reviews it. Of those rows it fixes what is safe and
small. Security rows are always fixed, and blockers only when your Quality row
says so, as Picking rows says. Every other surviving house-rule row or Major
row you do not fix goes in `## Follow-ups`, with the reason. Size decides fix
or record, never drop. A row that blocks the feature is a question.

R0 writes the full facts; S0 owns the shape.

## Not met always

A Not met verdict on a requirement or a plan decision never goes in
`## Follow-ups`, in any mode, `Size: Trivial` included: a fixer fixes it, then
one `--fixes` review checks it, with no round left too, before the final
fixer. A Not met it cannot fix is a question.

## Later rounds and the CI fix

A requirement a `--fixes` review answers "unchanged" keeps its latest verdict.
A fixer names what its fix touched on its report's `Touches:` line, which is
recorded with it. One that touches what your Quality row's Full review of a
fix to names gets a review of the whole branch: no `--fixes`. So does an
implementer's CI fix with no `Touches:` line. A CI fixer also gets R0 when
its fix changes what the body says, in place after S0. Notify only on ready.
