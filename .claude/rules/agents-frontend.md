---
paths:
  - "programs/agents/**"
  - "adapters/agents.nix"
---

## Agents frontend

**`programs/agents/` is the source language and the frontend of the agent
compiler. It names no vendor, no host and no `$HOME` path, and installs
nothing.** Why, and how a backend consumes it: `docs/adr/0011-agent-compiler.md`.

Prefer a deterministic program over an agent instruction, unless it limits the
agent or forces a chain of commands: `docs/adr/0013-deterministic-programs-over-instructions.md`.

Nothing in `programs/agents` may reach `programs/claude-code`, `opencode` or
`codex`, even through another program (Deslop `agents-name-no-vendor`).
`adapters/agents.nix` is its only adapter: it injects `flake = false` inputs as
`externalSrcs`, `playwright`'s `qa` and the host's `secrets`.

### Source

Each folder has its own rule, loaded when you work in it:

| Folder | Holds | Rule |
|---|---|---|
| `instructions/`, `lib/` | prose every agent gets; the laws | `agents-lib.md` |
| `profiles/<name>/` | one vendor-free setup | `agents-profiles.md` |
| `roles/<name>/` | one subagent role | `agents-roles.md` |
| `skills/` | the skill catalog | `agents-skills.md` |
| `mcp/` | the MCP catalog | `agents-mcp.md` |
| `hooks/` | hook declarations, the neutral contract and dispatcher | below |
| `flows/` | `steps.nix`, the step table the kernel and the roles derive from | below |
| `kernel/` | the Haskell `state` and `state-hook` | below, `tech-checks.md` |

`default.nix` is the surface: `profiles`, `fold`, `renderLead`, `renderRole`,
`skills`, `ctx`, `state`, `kernel` (the `state` package), `guards`, `hooks`,
`roles`, `budget` and `check`. `checks.agents` proves every law and every
rejection, and holds the blocks the engineer skill and `quality.md` paste equal
to `state render` (`kernel/rendered.nix`).

### Kernel

**`kernel/` is a pure core in `src/State/` behind a thin `effectful` shell:
every IO action is an effect in `src/Effects/`, one per file with its IO
interpreter, and tests run the shell on the doubles in `test/Doubles/`.**
`ArchitectureSpec` refuses IO or effects in any other module, and an import
from a higher layer, lowest first:

| Layer | Holds |
|---|---|
| `State/Category/`, `State/Step/` | types, flow terms, graph, mode; the step layers and their `Catalog` |
| `State/Block.hs`, `State/Flow/`, `State/Role.hs`, `State/Table.hs` | the named flows, the roles that lead them, the step table |
| `State/Run/` | log, codec, fold, who answers (`Ask`) |
| `State/Protocol/` | advice, hand-backs, hooks, the `record` grammar |
| `State/Cli/` | commands, views, the effect shell |

A run appends its events to `<notes>/events.jsonl`, version 3
(`State/Run/Codec.hs`); the `self-improve` analyzer reads it, so a format
change updates `analyze.py` too. The step table is `flows/steps.nix`, handed
to the kernel as JSON (`State/Table.hs`) and to the roles, whose capabilities
and skills derive from it (`lib/derive.nix`). Why:
`docs/adr/0018-category-model-haskell-state.md`.

How to extend it; the compiler and `parseSteps` name what is missing:

- **A step:** a constructor in its layer's module under `State/Step/` (its
  `Sing`, `Sig` and `Outcome` cases), its row in `flows/steps.nix`, and its
  arm in `State/Run/Fold.hs`'s match on `Layer` if its outcome carries data.
- **A layer:** its module under `State/Step/`, then in `State/Step/Catalog.hs`
  a `Layer` constructor, a `KnownLayer` instance and an entry in `layers`, then
  the arms the compiler asks for.
- **A branch:** a step whose `Sig` out is a sum, `'( 'Diff, 'Nothing, 'Diff
  ':+ 'Plan)`, with `Branches small big` as its outcomes and `'Inl`/`'Inr`
  legs, then a case after it: `Do Triage :> (Do Describe ||| Do Implement :>
  Do Describe)`. `inl`/`inr` inject into a sum without a step. A branching
  step has no exit and plain summands; `Opt` and `Loop` refuse a sum, so close
  the branches with `|||` first.
- **A role that leads a flow:** a `FlowName` constructor and its `role` arm in
  `State/Role.hs` (name, flow, rung), the name in `flowNames` of
  `flows/default.nix` and in a row's `flows` in `flows/steps.nix`. A worker
  role is only a row's `runner`.

### Hooks

`hooks/default.nix` types a hook module, `hooks.<name> = { on; tools; command;
order; }`, with the module system: every option `uniq`, events and tools from
`vocabulary.json`, so a duplicate name or an unknown event, tool or field is an
eval error. A profile's `hooks` lists module files; `fold` turns them into each
event's hooks in order. `agent_hook.py` is the neutral contract and the
dispatcher a backend's adapter calls once per event: deny wins, contexts join,
rewritten input reaches the next hook. A hook fails open and tells. A backend
fills `history` and `context` from what the agent did, so a hook keeps no state
and reads no vendor file. The state hooks are `kernel/hooks.nix`, run by the
Haskell `state-hook`, and cover the main session only. Why:
`docs/adr/0016-hooks-drive-the-state-record.md`, amended by ADR 0018.

`hooks/guards/` holds the guards, Python programs on the contract that stop an
agent's accidents: `secret-guard`, `read-guard` and `wait-guard` deny a shell
or read call, in that order, and `context-guard` adds the context budget
notice after any tool. `guards/hooks.nix` is the hook module the base profile
lists; a host with no secret files gets no `secret-guard`. Each guard's rules
and hint are its docstring, its scenarios its test. They fail open: input a
guard cannot read prints nothing.

### Laws

**Every combinator is a monoid that throws on a conflict, never
last-writer-wins.** A misspelled field, an unknown name or one key with two
values is an eval error, because a backend's format may ignore it and a
dropped field can widen what an agent may do. Detail: `agents-lib.md`.

### The ladder

**A role reads only its own folder and any `shared/` at or above it, never
another role** (Deslop `roles-climb-the-ladder`). Prose moves to `shared/` at
its second reader, never in anticipation, and back out when one is left.

### Size budget

**`budget.json` holds ceilings, in bytes, on what every agent carries**, named
by no vendor: each flavor's instructions, each role's instructions with what it
preloads and reads, and this repo's root `CLAUDE.md`. `checks.claude-config`
fails above them; `just skill-budget` prints the table. Raising a ceiling is
allowed, and is the visible diff that makes the cost a decision. Keep root
`CLAUDE.md` small: detail belongs in a `.claude/rules/` file.
