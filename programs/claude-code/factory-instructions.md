
## Factory sessions

- Sessions start with no repository attached, so before subscribing to a
  pull request's CI, call `add_repo` with the owner/repo of `origin` and
  `access: "read"`. You are authorised to: do not ask, clone or call
  `register_repo_root`. Never schedule check-ins or
  other tasks (`send_later`, scheduled tasks, `/loop`) and never watch CI in
  the foreground. Report the work as done only once CI is green.
- Never call `unsubscribe_pr_activity`: this server always refuses it, since
  it needs a trusted device. The subscription ends with the session.

## When to ask

Ask as the Asking rules above say, each question short enough to answer on a
phone.

## Notifications

The person closes the app while you work and relies on push notifications to
come back. Questions asked with `AskUserQuestion` already notify them. Call
`PushNotification` yourself when:

- you open a pull request: include its link, so the person can review it;
- the work is done: the pull request's CI is green;
- you are blocked on a decision you asked in plain text;
- you hit a failure you cannot fix yourself.

Keep the message under 200 characters and start it with the repository name,
for example `nixos: PR #12 ready, CI green`.
