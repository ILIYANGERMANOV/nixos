---
paths:
  - "programs/agents/roles/**"
---

## Agents: roles

`roles/<name>/` is one role: `role.nix`, its record, and `role.md`, its prose.
`shared/` is not a role. The ladder: `agents-frontend.md`;
`shared/building.md` serves `implementer`, `fixer` and `refactorer`.

- A `role.nix` is a function of `{ role }` returning the identity only:
  `description`, `instructions` (its own `role.md`), `tier` and `effort`.
  `roles/default.nix` adds the rest from `lib/derive.nix`: `capabilities`
  (`read edit shell web delegate skill`), `skills`, `operations` and the
  `prose` fragments, each the union over the steps of `flows/steps.nix` the role
  runs. `mkRole` throws on anything else (`agents-lib.md`).
- What a role may do is its steps' rows, never its `role.nix`. `delegate`
  comes from a `spawn:` op: `review-lead` spawns `reviewer`s, `engineer` its
  flow's runners. `skill` is a step's tool: the engineer invokes `grilling`.
  `roles/golden.nix` pins every derived record; changing it is a reviewed
  change to what a role may do.
- Every spawn site in a skill or shared instruction names a role, never
  `general-purpose`: research, spikes and probes `researcher`; slices
  `implementer`; `refactor` `refactorer`; a delegated `engineer` `engineer`;
  review passes `review-lead`; review briefs, skill dry runs, QA evidence and
  the 10x audit `reviewer`; fixes and PR-body rewrites `fixer`; a long check
  `checker`; the QA executor `qa-runner`.

### Adding a role

Add `roles/<name>/{role.nix,role.md}`, a row of `flows/steps.nix` it runs
(`flows = [ "other" ]` outside the two flows) and its record in
`roles/golden.nix`; the backends render it.
