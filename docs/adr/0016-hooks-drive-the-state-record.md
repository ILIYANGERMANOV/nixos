# Hooks drive the `state` record

ADR 0015 made `state` the engineer flow's record, written by the lead as each
step happens, and left hooks out "for now": the enforcing ones measured 0
violations. This ADR amends that. Advisory hooks now write every event a
program can derive, and inject `state` and `ctx` context where it is used. The
lead records only what it decides. Design and implementation: #335, PR #339.
ADR 0017 amends it: PR state is read from GitHub, not from shell commands,
and the `pr` hook is gone. ADR 0018 amends it: the Haskell `state-hook`
replaces the Python hooks, and keys each event on a content hash, so a hook
that fires twice appends once.

## Evidence

ADR 0013 asks for the measured cost a hook removes. Run 33c5fcbd (#333), an
`/engineer` run under `state`:

- No `state` call for the first 61 minutes, then back-filled.
- 37 calls, all from the lead: 4 overrides and 4 failures.
- 5 hand-backs retyped into `state handback`, one of them failing to parse.
- Steps 9 and 10 ran with no `state` call at all.

So the record drifts the way ADR 0015's progress file did: the model forgets
to write it. What it forgets is mechanical: a hand-back's status and head, a
`gh pr create` URL, a question asked. A hook derives each from the tool call.

## Decisions

- **Advisory, fail open and tell.** No hook denies. A hook that fails, or a
  `state` refusal, lets the call go on and adds `state hook <name>: <error>`
  and the refusal's `fix:` line to the agent's context.
- **The hooks** (`programs/agents/state/hooks.nix`, `state-hook <name>`). Each
  does nothing in a worktree with no run, or with a run at `Done`.

  | Hook | When | Does |
  |---|---|---|
  | resume | session start, resume, compact | adds `state show` and `state next` |
  | spawn | before the lead delegates | adds `state next` and a warning when a flow role off the advised one is spawned; never rewrites the prompt: auto mode refuses a rewritten spawn once, so `state brief` gives a refactorer, review-lead or fixer a `Diff:` line to run `ctx diff` itself |
  | handback | before a worker hands back | records it, and appends what it recorded, or the refusal and `fix:`, to the report |
  | pr | after `gh pr create`, `gh pr ready` run as a command | records `drafted`, `ready`; removed by ADR 0017 |
  | asked | after the lead asks, in Ctx | records `asked` |

- **What stays manual** is what only the model decides: Size, Quality,
  `planned`, `proposed`, `confirmed`, `adjusted`, a review's `picked` rows and
  verdicts, a question's `blocked <kind>` triage, `resolved`, `ci`. A
  hand-back question stays untriaged until the lead records its kind, and
  `state next` advises it. `handback --head`, `--row`, `--verdict` and
  `--touches` are gone: the head is the worktree's, a review-lead's report
  carries `Reviewed head:`, a fixer's a `Touches:` line.
- **A vendor-free hook abstraction.** `programs/agents/hooks/` declares hooks
  with the Nix module system: `hooks.<name> = { on; tools; command; order; }`,
  events and tools from `vocabulary.json`, every option `uniq`, so a duplicate
  name, an unknown event, tool or field is an eval error. A profile lists hook
  module files in its `hooks` field.
- **A neutral contract.** A hook is a program reading one event as JSON
  (`event, tool, input, output, cwd, session, agent, source`) and printing one
  result or nothing (`agent_hook.py`). Each event has its own result type: a
  beforeTool hook prints a verdict (`decision, reason, context,
  updatedInput`); a sessionStart or afterTool hook only a note (`context`),
  since nothing is left to deny or rewrite.
- **One dispatcher per event, in the frontend.** A backend registers one entry
  per event; its adapter hands the event to `agent_hook.dispatch_verdict` or
  `agent_hook.dispatch_note`, which run the matching hooks in `order` and fold
  their results as a monoid: deny wins, contexts join, a rewritten input
  reaches the next hook. Claude runs its
  own hooks in parallel with no defined winner for a rewrite; OpenCode runs
  them in order. The dispatcher makes both the same.
- **Claude Code is the first backend.** `codegen/hooks.nix` maps the events to
  `SessionStart`, `PreToolUse` and `PostToolUse`, and the tools to a matcher
  through `codegen/tools.nix`, the one tool table roles use too; a tool with no
  Claude name throws. `hooks/adapter` (`agent-hook-claude`) translates Claude's
  JSON to the contract and back. Claude honours `updatedInput` on
  `SubagentHandback` and on `Agent`'s prompt (probed with 2.1.314).

## Scope

The hooks cover the main session, whose hook `cwd` is its worktree. A
subagent's hook `cwd` is the folder its spawner was in at the spawn, and its
own `cd` resets after each call (probed with 2.1.314). No payload field names
a subagent's spawner. So a delegated engineer's hooks never find its own run, and
it records every step by hand, as before. Considered and out of scope:
delegated engineers as top-level sessions, reading the worktree from the call,
and Claude's internal `subagents/*.meta.json` link.

## Considered options

- **Keep prose only.** Rejected: run #333 above.
- **One settings entry per hook, no dispatcher.** Simplest codegen, but order
  and input rewrites would differ per vendor.
- **Claude-native hook commands.** Less code now, but an OpenCode backend
  would rewrite every hook.
- **Hooks that deny** (a spawn out of order, a Stop hook refusing "done").
  Still out: ADR 0015's reason holds, and a refusal that blocks work costs
  more than one that tells.

## Consequences

- The engineer skill teaches what each hook adds and how to act on it, and
  keeps only the records the lead decides. `state help`, `show` and `next`
  still work by hand.
- A diff-reading worker runs the `ctx diff origin/<base>` its brief's `Diff:`
  line names, then reads its `index` first and the diff ranges.
- The 4 Claude-native guards stay as they are; porting them to the contract
  is #338. An OpenCode backend reuses every hook through a generated plugin.
- Logs written before `picked` existed, whose `reviewed` event held rows and
  verdicts, no longer parse. They live in `/tmp` and are not migrated.
