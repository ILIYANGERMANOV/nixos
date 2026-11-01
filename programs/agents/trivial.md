
## Trivial

**Trivial** is automatic and per task, with no picker. While a task qualifies
it overrides POC, Balanced and Max, and the result is still merge-ready.

- It qualifies by judgment, not by a list of kinds: clear, a revert undoes it,
  about 100 changed lines, generated lockfiles aside. Local UI state, any
  dependency bump and a small fix with a red test qualify.
- Never: auth, CI, database, secrets, deploy, the data model, or skills and
  instructions beyond a typo. A bump is CI, so never, when it changes a GitHub
  Actions `uses:`, or `flake.nix` or `flake.lock` while a workflow holds push
  credentials: check before implementing.
- Engineers assign it. A skill reads its own input and brief, may activate it at
  any point, also mid-run, and skips its expensive work. A brief says
  `Quality: <mode>, Trivial`.
- Anything that stops qualifying moves to the user's Quality, Balanced if they
  named none, and never comes back: its prompts say `Quality: <mode>, not Trivial`.
- Steps: `~/.claude/skills/engineer/references/trivial.md`, read only when used.
