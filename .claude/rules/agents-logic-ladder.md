---
paths:
  - "programs/agents/**"
  - "adapters/agents.nix"
  - "programs/claude-code/**"
  - "programs/opencode/**"
  - "programs/codex/**"
  - "adapters/claude-code.nix"
---

## The logic ladder

**Agent behaviour lives on the first rung that can hold it: pure Haskell
(the kernel's no-IO modules) >> impure Haskell (the kernel's effect shell,
e.g. `kernel/src/State/Cli/Shell.hs`) >> hooks (`kernel/hooks.nix`,
`state-hook`) >> prose (skills, roles, instructions).**

Each rung further from the kernel is less deterministic and less testable:
pure code has property and golden tests, the shell runs on the doubles in
`test/Doubles/`, a hook works only when the client fires it, and prose only
when a model reads and obeys it. The logic ladder refines
`docs/adr/0013-deterministic-programs-over-instructions.md`.

Pick the rung by asking, in order:

- Can the kernel decide it from its log and arguments? Pure Haskell.
- Does it need the filesystem, git or the clock? The effect shell.
- Does only the client see the moment (a tool call before it runs, a spawn,
  a hand-back)? A hook.
- Is it judgment, taste or a fallback sentence, or would a program limit the
  agent or force a chain of commands (ADR 0013)? Prose.

What follows:

- The kernel is the source of truth.
- Prose may repeat a kernel or hook rule as encouragement, context or
  confirmation, but never contradicts the kernel.
- A rule never lives only in prose when it could be code.
- When prose keeps getting broken, move the rule toward the kernel.
- A hook is a thin adapter calling a kernel function, and never holds logic
  the kernel could hold.

Examples: the next action and its refusals are pure kernel code
(`State/Protocol/Advice.hs`, `state next`). The spawn record comes from the
`state-spawn` hook running `state-hook spawn` before a delegate call, while
the engineer skill's "`state` holds the record" repeats it as context.
