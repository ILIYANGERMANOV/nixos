# Trivial fast track

The rule is under `## Trivial` in your instructions: what qualifies, and the
never-list. These are its steps. Numbers are `engineer`'s steps, so a
report file and a resume read the same. No step here relaxes a gate.

## Steps

1. **Judge, before step 1.** The prompt and at most 5 lookups by you, no
   Quality question and no proposals. Ambiguity, or anything the user might
   want different, gets one question, and the track goes on if the answer keeps
   it small.
2. **Implement, step 5.** One `implementer` agent, briefed `Quality: <mode>,
   Trivial`, with the task, a short plan inline, its branch from
   `origin/main`, its targeted checks, the stop rule from `blockers.md` and
   "commit and push". A bug fix comes with a test that was red before it.
3. **Open, step 4.** A draft PR, with the `pr-description` short form, the same
   short plan and the line `Quality: <mode>, Trivial`, attached to the session
   as step 4 says. No confirm question. Start the progress file.
4. **Sweep, step 7.** One fresh `review-lead` agent, no children: "invoke `pragmatic-review`
   with: Quality: <mode>, Trivial <PR URL> <the task in one line>", plus the
   stop rule. There is no refactor and no re-review.
5. **Final small fix, step 8.** The sweep's rows go to one `fixer` agent,
   briefed the same way, as `review.md`'s final small fix says: security rows
   always, the rest when safe and small, no review after it. Other rows go in
   `## Follow-ups`. A Not met it does not settle leaves the track.
6. **Hand over, step 10.** Step 9 only rewrites the body when the fix changed
   what it says, and notifies nobody. Wait for CI the non-blocking way your
   instructions describe. A CI failure goes to a fixer and straight back to
   CI: there are no rounds. On green, answer any review comments,
   `gh pr ready`, and notify. The user merges. No next steps listed.

A fact gap, at any step: the fact path in `blockers.md`, with one small
researcher. The task stays Trivial.

## Leaving the track

Leave when the sweep returns `Escalate`, the implementer's diff stops qualifying,
a decision or new scope appears, the fix above says so, CI is red twice for
one cause, or the user asks. It is one way:

1. No PR yet: open the draft now, as Open says, on an empty commit if nothing is
   pushed.
2. Set the PR's line to `Quality: <mode>, not Trivial`, Balanced if the user named
   none, and add `Security-sensitive: <topics>` when one applies. Every prompt
   carries the new line.
3. Add acceptance criteria to the PR body, the task as checkable statements, for
   step 7's requirements file.
4. Go back by what is open, on the same branch:
   - **A decision, or scope nobody asked for** (a new column): the decision
     path in `blockers.md`, so step 3 runs at the new Quality with its
     proposals. Put the confirmed plan in the PR body, then go on from step 5.
   - **Nothing open, the diff only fails the check:** tell the user why in one
     line and resume at step 6.

## Delegated

Run implement, open, sweep and fix in the foreground, then step 10's part as the
`Delegated` section says, and stop before the CI wait: the rest is your caller's,
and its gates are the same. Leaving the track, tell your caller in the hand-back
with `Trivial dropped: <why>`, and go on to the rest of `Delegated`. An open
decision or new scope stops there, as `NEEDS_DECISION`.
