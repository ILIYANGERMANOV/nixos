# The review loop

Steps 7 and 8, and step 10's CI fix. You drive the loop: a fresh review-lead
per round, a fixer between rounds. `state next` prints each round's spawn, its
`--fixes` arguments, the requirements copy, the dry run and the final fixer's
rows; your Quality row's Re-reviews count the rounds, and the skill's stuck
guard ends the loop early. Never load `pragmatic-review` yourself.

## Requirements

Write the requirements once per plan, where `state next` names them. They are
the acceptance criteria plus what must hold where you are least sure of the
implementation. Each of the plan's decisions is a requirement too, met only
when the diff follows it. The out-of-scope list goes with them as assumptions,
in your words, so a deliberately skipped edge case is not raised. A
`Security-sensitive:` line adds the requirement `security-sensitive: <topics>`.
Every review, the Trivial sweep included, gets `--requirements <path>`, never a
list or a copy. /final-review gets this original file.

## Picking rows

You answer the pickers by acting on the table yourself. Never reply to the
review agent with an action. Choose the rows worth fixing. Every surviving
house-rule row is fixed, or the reason for leaving it goes in the PR body.
When your Quality row fixes only blockers (security, irreversible damage,
broken code), every other row goes in `## Follow-ups`. A Not met verdict
never does: `Not met always` below. Below the Re-reviews cap, chosen rows
go to a loop fixer, then a `--fixes` review: record them as `picked`'s
`--row`s, and `state next` spawns it. No row chosen, or the cap, ends the
loop: the final fixer.

A return that starts `NEEDS_DECISION plan wrong`: fix no row, security
included. Record its rows and triage the line. The re-plan's fresh round 1
finds them again.

## Final fixer

The loop's one exit, in every mode, and it only follows the loop: after a
review with no row chosen, or at your Quality row's Re-reviews cap. One fixer
gets R0 and, at the cap, that last review's chosen rows, and nothing reviews
it. Of those rows it
fixes what is safe and small. Security rows are always fixed, and blockers
only when your Quality row says so, as Picking rows says. Every other surviving
house-rule row or Major row you do not fix goes in `## Follow-ups`, with the
reason. Size decides fix or record, never drop. A row that blocks the feature
is a blocker: triage it.

## Not met always

A Not met verdict on a requirement or a plan decision never goes in
`## Follow-ups`, in any mode, `Size: Trivial` included: a fixer fixes it, then
one `--fixes` review checks it, at the cap too, before the final fixer, which
always runs last. A Not met it cannot fix is a blocker: triage it.

## Later rounds and the CI fix

A requirement a `--fixes` review answers "unchanged" keeps its latest verdict.
A fixer names what its fix touched on its report's `Touches:` line, which the
hook records. One that touches what your Quality row's Full review of a fix to
names gets a review of the whole branch. The CI fix loops as `state next`
says until CI is green; a CI fixer also gets R0 when its fix changes what the
body says. Notify only on ready.
