---
paths:
  - "programs/agents/profiles/**"
---

## Agents: profiles

`profiles/<name>/profile.nix` - one folder per profile, found by `readDir`. A
profile is the vendor-free part of one setup: `skills`, `instructions`, `mcp`
(server names), `runtime` (packages on PATH), `secretFiles` (variable ->
secret name) and `hooks` (hook module files, `agents-frontend.md`). Profiles are deltas and never import each other; a backend's
flavor lists the ones it gets. `mkProfile` and `append` are in `agents-lib.md`.

- `base` - every flavor: the shared skills, `agent.md`, `lead.md`,
  `trivial.md`, `runtime` (`programs/playwright`'s `qa`, `ctx` and `state`),
  `secretFiles` and the state hooks.
- `web-ui` - figma.
- `pm` - `self-improve`, linear, superhuman-docs.
- `local` - `10x-engineer` and its `lead.md` for the lead only: every
  non-factory flavor.
- `factory` - `10x-engineer`, `self-improve`, `android`, its `agent.md` in
  `forAll` and its `lead.md` for the lead only.

Every flavor gets every shared skill, `ui-coding` included: a model-invoked
skill costs only its description.

`secretFiles` maps a variable to a secret **name**, for a program that reads
the file itself: the backend exports the decrypted file's **path**, never its
value (`QA_EVM_KEY_FILE` -> `qa-sepolia-key`, on `macos-work` only). A host
without the secret gets no variable.

### Adding things

- **Profile**: add `profiles/<name>/profile.nix`, then list it in a flavor.
- **Tool on PATH**: add the package to a profile's `runtime`.
