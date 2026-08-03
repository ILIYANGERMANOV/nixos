# Custom skills

Hand-written [Agent Skills](https://agentskills.io) committed to this repo and
installed into `~/.claude/skills/` by the Claude flavor wrappers.

## Adding a skill

1. Create `programs/skills/custom/<name>/SKILL.md`.
2. Add `"<name>"` to the `custom` list in `../default.nix`.
3. Add it to `baseSkills` (or a flavor's `extraSkills`) in
   `../../claude-code/default.nix`.
4. `darwin-rebuild switch --flake .` — then restart Claude Code if
   `~/.claude/skills` did not exist when the session started.

A directory left out of the `custom` list stays committed but uninstalled, which
is how to keep a draft in version control.

## Format

The directory name is what you type as the slash command, and the frontmatter
`name` must match it — `just check` fails otherwise.

```markdown
---
name: my-skill
description: What it does and when to use it. Claude reads this to decide when to apply the skill. Put the key use case first.
---

# My skill

Instructions to the agent, in plain Markdown.
```

Required frontmatter: `name` (matching the directory, `^[a-z0-9]+(-[a-z0-9]+)*$`)
and `description` (at most 1024 characters, the Agent Skills limit). Useful
optional fields include `disable-model-invocation: true` for workflows you only
ever want to trigger yourself with `/name`, `allowed-tools`, `argument-hint` and
`context: fork`.

## Bundled files

A skill may ship supporting files next to `SKILL.md` — templates, checklists,
scripts. Reference them through `${CLAUDE_SKILL_DIR}`, never a relative path, so
they resolve through the Nix store symlink:

```markdown
Read `${CLAUDE_SKILL_DIR}/checklist.md` before starting.
```

## Editing

Skills are symlinked from the Nix store, so they are read-only and a change
needs a rebuild. Claude Code watches the directory and picks the change up
without a restart once the rebuild lands.

To iterate faster, prototype in a project's own `.claude/skills/` and move the
directory here when it settles. Do not prototype directly in `~/.claude/skills/`
— each flavor wrapper wipes and relinks that directory on launch.
