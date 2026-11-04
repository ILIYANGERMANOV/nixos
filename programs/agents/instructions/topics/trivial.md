
## Trivial

`Size: Trivial` is the engineer's call, made once per task. It skips steps of
the user's Quality and never adds any; the result is merge-ready except at POC.

- It qualifies by judgment, not by a list of kinds: clear, a revert undoes it,
  about 100 changed lines. Local UI state, any dependency bump and a small fix
  with a red test qualify.
- Never: auth, CI, database, secrets, deploy, the data model, or skills and
  instructions beyond a typo. A bump is CI, so never, when it changes a GitHub
  Actions `uses:`, or `flake.nix` or `flake.lock` while a workflow holds push
  credentials: check before implementing.
- A worker never switches it on. On `GREW`, or when it stops qualifying, the
  engineer sets `Size: Normal` for good.
- What it skips: `~/.claude/skills/engineer/references/trivial.md`, read only
  when used.
