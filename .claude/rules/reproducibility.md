---
paths:
  - "programs/**"
  - "modules/**"
---

## Reproducibility

**Config plus any prior state gives the same result on what Nix owns.
Everything else is untouched. Applying twice equals applying once.**

### The law

For a config `C`, `O` = the paths and keys `C` owns, and any prior system
states `S1`, `S2`:

```
convergent: apply(C, S1)|O == apply(C, S2)|O
untouched:  apply(C, S)|¬O == S|¬O
idempotent: apply(C, apply(C, S)) == apply(C, S)
```

Nix eval and the store are reproducible already. The risk is the effect
shell: activation scripts, wrappers and systemd units. That is where a result
can start to depend on what was there before, or on what ran first.

### Ownership classes

Every path an effect touches is in exactly one class.

| Class | What Nix does | Example |
|---|---|---|
| Owned | replaces it fully | a role file under `~/.claude/agents/<role>.md` |
| Keyed | sets only its keys in a file the tool also writes | `.mcpServers` in `~/.claude.json` |
| Untouched | never writes it | Claude Code's own `synced/` under `~/.claude/skills` |

- **Owned**: write the whole thing from config. No merge, no backup, no
  "if it exists".
- **Keyed**: merge only the keys config owns; leave every other key as found.
- **Untouched**: no effect deletes or rewrites it, even in passing, such as
  an `rm -rf` of its parent.

### Effect scripts

- Never branch on prior state: no "if missing, create", no "if old, migrate"
  that leaves a different result than a fresh apply.
- Never depend on run order: the outcome is the same whichever wrapper,
  activation or unit ran last.
- Replace atomically (write, then rename), so a reader never sees a half
  state.

### Known violations

Not fixed yet. Each makes the result depend on prior state.

| Case | Why the result depends on prior state |
|---|---|
| Macs: flavors share `~/.claude` | the flavor launched last wins |
| Macs: rebuild writes the base settings | running sessions lose their flavor extras |
| Factory: settings written at server start | stale until some server restarts |
| Macs: `rm -rf ~/.claude/skills` | also deletes Claude's own `synced/` |

Do not copy these patterns into new code.
