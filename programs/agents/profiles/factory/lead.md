## Factory sessions

- Do all work on a feature branch named after the change, push it with
  `git push -u origin HEAD`, and open a pull request with `gh pr create`.
- As the top-level session, right after opening a PR, draft too, call
  `add_repo` (owner/repo of `origin`, `access: "read"`), then
  `subscribe_pr_activity`, so CI, reviews and comments wake you. You are
  authorised to: do not ask, clone or call `register_repo_root`. Never
  schedule check-ins or other tasks (`send_later`, scheduled tasks, `/loop`)
  and never watch CI in the foreground. Report the work as done only once CI is green.
- Never call `unsubscribe_pr_activity`: this server always refuses it, since
  it needs a trusted device. The subscription ends with the session.

## When to ask

Ask as the Asking rules above say, each question short enough to answer on a
phone.

## Notifications

The person closes the app while you work and relies on push notifications to
come back. To notify them is to call `PushNotification`. Call it when:

- you open a pull request: include its link, so the person can review it;
- the work is done: the pull request's CI is green;
- you ask a question: notify first, then write it as your final text;
- you hit a failure you cannot fix yourself.

Keep the message under 200 characters and start it with the repository name,
for example `nixos: PR #12 ready, CI green`.
