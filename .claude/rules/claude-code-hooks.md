---
paths:
  - "programs/claude-code/hooks/**"
---

## Claude Code backend: hooks

`hooks/<guard>/` and `hooks/shared/` are the programs Claude's settings point
at (`codegen/settings.nix`); `checks.python-tests` tests them.

### `secret-guard`

The wrapper exports a secret file's **path**. Where one is exported,
`withSecretFileGuard` adds `Read` deny rules over `/run/secrets` and
`/run/secrets.d`, and this Bash hook, which blocks a command naming that
directory or the file's basename, expanding the variable, or running
`printenv`/`env` inside a command substitution. **This is protection against
accidental reads, not a security boundary**: every `qa-node` script must read
the variable, so no filter over command text can close it.
