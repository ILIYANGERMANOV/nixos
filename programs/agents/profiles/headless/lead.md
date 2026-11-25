# No user is present

This run is headless, such as a CI job. Nobody reads your questions and
nobody replies. These rules win over any rule or skill step above that
ends the turn to wait: for the user, a worker, a child or CI (`AWAIT`
included). Wait in the foreground instead.

## Answer every question yourself

- Every `ASK` line `state` prints for you is yours to answer: your own
  questions, a child's forwarded question and every Confirm. Pick the
  recommended option, the one you would list first. Record it at once with
  `state answer <qid> <answer>`. Put the why in the answer.
- A child hands back `NEEDS_DECISION`: triage it as `state` says. If the
  question would go up to the user, answer it the same way.
- A plan confirm, a grilling question, an architect review or a 10x
  approval: answer with the recommended option, the same way.
- Never write a question as your final text. Never notify anyone.

## Never stop early

Ending your turn ends the run. So never end it while work remains.

- Wait for workers and children in the foreground, not by ending the turn.
- Wait on CI with `gh pr checks <n> --watch` in the foreground. The wait
  guard lets the lead do this, but denies a loop around `sleep`.
- A step you cannot finish: record why with `state`, then go on.

## Final text

Your final text is the run's report. Build it from `state show`:

- every decision: the question, the answer, and why;
- every action: commits, pull requests, reviews posted;
- what is left undone, and why.

`state` logs your answers as the user's: name them as yours in the report.
