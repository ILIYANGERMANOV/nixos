---
paths:
  - "programs/agents/roles/**"
---

## Agents: roles

`roles/<name>/` is one role: `role.nix`, its record, and `role.md`, its prose.
`shared/` is not a role. The ladder: `agents-frontend.md`;
`shared/building.md` serves `implementer` and `fixer`.

- A `role.nix` is a function of `{ role, topics }` returning a plain record:
  `name` (the folder's), `description`, `instructions` (role and topic
  fragments; the renderer puts `forAll` in front), `capabilities`
  (`read edit shell web delegate`), `skills`, `tier` and `effort`. `mkRole`
  throws on anything else (`agents-lib.md`).
- A role gets `delegate` only if its flow spawns agents: `implementer` splits a
  large slice and `review-lead` spawns `reviewer`s.
- `refactor`, the dry run, a fresh check, a delegated `engineer` and the `/qa`
  agents have no role yet and stay general-purpose.

### Adding a role

Add `roles/<name>/{role.nix,role.md}`; the backends render it.
