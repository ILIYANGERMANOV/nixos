# Trivial fast track

The rule is under Quality in your instructions: what qualifies, and the
never-list. These are its steps. Numbers are `engineer`'s lifecycle steps, so a
report file and a resume read the same. No step here relaxes a gate.

## Steps

1. **Judge, before step 1.** The prompt and at most 5 lookups by you, no research
   agent, no plan, no Quality question. Ambiguity, or anything the user might
   want different, gets one question, and the track goes on if the answer keeps
   it small.
2. **Implement, step 5.** One implementer, briefed `Quality: <mode>, Trivial`,
   with the task, its branch from `origin/main`, "invoke `engineering` first",
   `ui-coding` for UI, its targeted checks, "commit and push" and
   `~/.claude/skills/engineer/references/implementer.md`. A bug fix comes with a
   test that was red before it.
3. **Open, step 4.** A draft PR, with the `pr-description` short form and the
   line `Quality: <mode>, Trivial`.
4. **Sweep, step 7.** One fresh agent, no children: "invoke `pragmatic-review`
   with: Quality: <mode>, Trivial <PR URL> <the task in one line>". There is no
   refactor.
5. **Fix.** An always-check row or a Not met goes to one fixer, briefed the same
   way. Its small fix gets one `--fixes` pass, the same way. A row or Not met
   left after that pass leaves the track.
6. **Hand over, step 10.** Wait for CI the non-blocking way your instructions
   describe. CI failures go to a fixer, and its diff gets one `--fixes` sweep as
   under Fix before ready. On green, answer any review comments, `gh pr ready`,
   and notify. The user merges. No app, QA or `/final-review`
   offers.

## Leaving the track

Leave when the sweep returns `Escalate`, the implementer's diff stops qualifying,
a decision or new scope appears, the fix pass above says so, CI is red twice for
one cause, or the user asks. It is one way:

1. No PR yet: open the draft now, as Open says, on an empty commit if nothing is
   pushed.
2. Set the PR's line to `Quality: <mode>, not Trivial`, Balanced if the user named
   none, and add `Security-sensitive: <topics>` when one applies. Every prompt
   carries the new line.
3. Add acceptance criteria to the PR body, the task as checkable statements, for
   step 7's requirements file.
4. Go back by what is open, on the same branch:
   - **A decision, or scope nobody asked for** (a new column): step 3 first, as a
     short plan and its question, research only when needed. Put the confirmed
     plan in the PR body, then go on from step 5.
   - **Nothing open, the diff only fails the check:** tell the user why in one
     line and resume at step 6.

## Delegated

Run implement, open, sweep and fix in the foreground, then step 10's part as the
`Delegated` section says, and stop before the CI wait: the rest is your caller's,
and its gates are the same. Leaving the track, tell your caller in the hand-back
with `Trivial dropped: <why>`, and go on to the rest of `Delegated`. An open
decision or new scope stops there, as `NEEDS_DECISION`.
