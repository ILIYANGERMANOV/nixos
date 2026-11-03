---
paths:
  - "programs/agents/roles/**"
---

## Agents: roles

`roles/<name>/` is one role: `role.nix`, its record, and `role.md`, its prose.
`shared/` is not a role. The ladder: `agents-frontend.md`;
`shared/building.md` serves `implementer`, `fixer` and `refactorer`.

- A `role.nix` is a function of `{ role, topics }` returning a plain record:
  `name` (the folder's), `description`, `instructions` (role and topic
  fragments; the renderer puts `forAll` in front), `capabilities`
  (`read edit shell web delegate skill`), `skills`, `tier` and `effort`. `mkRole`
  throws on anything else (`agents-lib.md`).
- A role gets `delegate` only if its flow spawns agents: `implementer` splits a
  large slice, `review-lead` spawns `reviewer`s and `engineer` runs the whole
  delegated lifecycle. Only `engineer` gets `skill`: it invokes skills it does
  not preload, such as `pr-description`.
- Every spawn site in a skill or shared instruction names a role, never
  `general-purpose`: research, spikes and probes `researcher`; slices
  `implementer`; `refactor` `refactorer`; a delegated `engineer` `engineer`;
  review passes `review-lead`; review briefs, skill dry runs, QA evidence and
  the 10x audit `reviewer`; fixes and PR-body rewrites `fixer`; a long check
  `checker`; the QA executor `qa-runner`.

### Adding a role

Add `roles/<name>/{role.nix,role.md}`; the backends render it.
