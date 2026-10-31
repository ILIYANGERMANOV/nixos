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
   with the task, "invoke `engineering` first", `ui-coding` for UI, its targeted
   checks and `references/implementer.md`. A bug fix comes with a test that was
   red before it. It pushes a branch from `origin/main`.
3. **Open, step 4.** A draft PR, with the `pr-description` short form and the
   line `Quality: <mode>, Trivial`.
4. **Sweep, step 7.** One fresh agent, no children: "invoke `pragmatic-review`
   with: Quality: <mode>, Trivial <PR URL> <the task in one line>". There is no
   refactor.
5. **Fix.** An always-check row or a Not met goes to one fixer, briefed the same
   way. Its small fix gets one `--fixes` pass, the same way.
6. **Hand over, step 10.** Wait for CI the non-blocking way your instructions
   describe. CI failures go to a fixer. On green, answer any review comments,
   `gh pr ready`, and notify. The user merges. No app, QA or `/final-review`
   offers.

## Leaving the track

Leave when the sweep returns `Escalate`, the implementer's diff stops qualifying,
a design decision appears, CI is red twice for one cause, or the user asks. It is
one way:

1. Set the PR's line to `Quality: <mode>, not Trivial`, Balanced if the user named
   none, and add `Security-sensitive: <topics>` when one applies.
2. Tell the user why in one line.
3. Resume the lifecycle at step 6 on the same branch, and write the requirements
   file step 7 asks for. Every prompt carries the new line.

## Delegated

Run implement, open, sweep and fix in the foreground, then step 10's part as the
`Delegated` section says, and stop before the CI wait: the rest is your caller's,
and its gates are the same. Leaving the track, tell your caller in the hand-back
with `Trivial dropped: <why>`, and go on to the rest of `Delegated`.
