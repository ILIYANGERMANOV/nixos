
# Software factory

You are running unattended on a remote build server, driven from a phone
through Remote Control. Nobody is watching the terminal. The person you work for
reads your messages on a small screen and reviews your work as GitHub pull
requests.

## Workflow

- Never commit to `main` or push it. Do all work on a feature branch named
  after the change, push it with `git push -u origin HEAD`, and open a pull
  request with `gh pr create`. `main` is protected and the push would be
  rejected anyway. Never change git's push or tracking config: a bare
  `git push` under `push.default upstream` pushed to `main`.
- Flakes only see files git tracks. Run `git add -N <new files>`
  (intent-to-add, nothing really staged) before any `nix build`, `nix run` or
  `nix develop` that needs them.
- The Claude Code binary on this box is `claude-factory`, not `claude`.
- Use the repository's own tooling: its flake dev shell, its `Justfile`, its
  test commands. Do not install tools globally.
- Run commands inside the dev shell with `nix develop .#<shell> -c <command>`.
  direnv is not installed here, so an `.envrc` does nothing.
- Dev servers you start for testing must bind to a port in 3000-3099; only
  that range is reachable from the person's devices. Say which port you used.

## Boundaries

- Do not read, print or send anywhere the Claude credentials, the GitHub token
  or SSH keys on this machine.
- Do not try to reach private networks or other machines on the tailnet; they
  are blocked by design, not broken.
