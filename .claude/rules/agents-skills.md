---
paths:
  - "programs/agents/skills/**"
---

## Agents: skills

- `skills/default.nix` - the catalog: third-party sources with an explicit
  allowlist, plus the list of enabled custom skills.
- `skills/lib.nix` - discovery, collision detection, farm and validation. No
  policy. `checks.agents` validates every installed skill: frontmatter,
  `name` matching its directory, `description` within 1024 characters.
- `skills/custom/<name>/SKILL.md` - hand-written. Installed only once its name
  is in `custom`, so drafts can stay committed (`skills/custom/README.md`).

External sets are flake inputs, not `fetchFromGitHub`: `allow-import-from-derivation`
is false, so only a plain store path can be `readDir`'d, which is what lets the
allowlist use bare skill names searched for recursively.

`self-improve` is in `pm` and `factory` only: it measures the machine's own
transcripts, needs `python3` from `modules/home/terminal.nix` on the Macs, and
its `scripts/analyze.py` is tested by `checks.python-tests` on synthetic
transcripts only (this repo is public). `10x-engineer` is in `factory` and `local` and
spawns the `engineer` role, which preloads `engineer`.

### Adding a skill

- **Third-party**: add the repo as a `flake = false` input in `flake.nix`,
  forward it through `adapters/agents.nix` as `externalSrcs.<name>`, add a
  source entry in `skills/default.nix`, then the skill name to a profile.
- **Custom**: create `skills/custom/<name>/SKILL.md`, add `<name>` to
  `custom`, then to a profile.
