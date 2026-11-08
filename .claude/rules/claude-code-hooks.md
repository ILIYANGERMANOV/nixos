---
paths:
  - "programs/claude-code/hooks/**"
---

## Claude Code backend: hooks

`hooks/<guard>/` and `hooks/shared/` are the programs Claude's settings point
at (`codegen/settings.nix`); `checks.python-tests` tests them. These guards are
Claude-native; porting them to the vendor-free hooks is #338.

### `adapter`

`agent-hook-claude <tools.json> <manifest.json>` is what `codegen/hooks.nix`
registers for a profile's vendor-free hooks (`agents-frontend.md`). It turns
Claude's hook JSON into the neutral event, runs the frontend's dispatcher in
process and prints the folded result as Claude's output. A tool with no
vendor-free name never reaches it. Input it cannot read exits 1, which Claude
shows and lets the call go on.

### `secret-guard`

The wrapper exports a secret file's **path**. Where one is exported,
`withSecretFileGuard` adds `Read` deny rules over `/run/secrets` and
`/run/secrets.d`, and this Bash hook, which blocks a command naming that
directory or the file's basename, expanding the variable, or running
`printenv`/`env` inside a command substitution. **This is protection against
accidental reads, not a security boundary**: every `qa-node` script must read
the variable, so no filter over command text can close it.
