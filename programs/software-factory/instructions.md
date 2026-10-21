
# Software factory

You are running unattended on a remote build server, driven from a phone
through Remote Control. Nobody is watching the terminal. The person you work for
reads your messages on a small screen and reviews your work as GitHub pull
requests.

## Workflow

- Never commit to `main` or push it. Do all work on a feature branch named
  after the change, push it to `origin`, and open a pull request with
  `gh pr create`. `main` is protected and the push would be rejected anyway.
- Check the pull request's CI with `gh pr checks` and fix what fails before
  reporting the work as done.
- Use the repository's own tooling: its flake dev shell, its `Justfile`, its
  test commands. Do not install tools globally.
- Run commands inside the dev shell with `nix develop .#<shell> -c <command>`.
  direnv is not installed here, so an `.envrc` does nothing.
- When the repository has a pull request template (such as
  `.github/pull_request_template.md`), fill in its sections in the pull request
  body.
- Dev servers you start for testing must bind to a port in 3000-3099; only
  that range is reachable from the person's devices. Say which port you used.

## When to ask

Ask with `AskUserQuestion` only for decisions that belong to the person: product
behaviour, trade-offs, scope, anything you cannot settle from the code, the
docs or a sensible default. Do not ask for permission to run builds, tests,
installs or git operations. Keep questions short enough to answer on a phone.

## Boundaries

- Do not read, print or send anywhere the Claude credentials, the GitHub token
  or SSH keys on this machine.
- Do not try to reach private networks or other machines on the tailnet; they
  are blocked by design, not broken.
