---
paths:
  - "programs/claude-code/hooks/**"
---

## Claude Code backend: hooks

`hooks/` holds Claude's side of the vendor-free hooks: the `contract` it
relies on and the `adapter` its settings point at. The hooks themselves, the
guards among them, are the frontend's (`agents-frontend.md`).
`checks.python-tests` tests both; its `adapter/test_guards.py` runs every
flavor's settings.json hook commands on Claude payloads shaped as the snapshot
recorded.

### `contract`

The hooks rely on what Claude Code sends and honours: payload keys, tool
names (`SubagentHandback` among them), `SessionStart` sources, cwd, and
`updatedInput`. `just probe-agents-hooks` snapshots that from the real client
against `model.py`, a scripted Messages API on 127.0.0.1, in auto mode, the
one mode that offers `SubagentHandback`. A Claude Code update must run it
(`dependency-updates.md`). A new request kind the mock does not know fails
with a 400 naming it: extend `model.py`, not the snapshot.

`just probe-agents-hooks --live` (`live.py`) runs one real haiku session with
the person's login: a typed skill, a Skill call, a denied Bash call and
subagents at depth 1 and 2, one in the background. Pure `checks` over the hook
payloads and the transcripts they name assert the events, their linked ids,
and that additionalContext and the deny reason reach the model. A transcript
line counts only through its `message`: the client also logs each hook's raw
output there. `test_live.py` runs them over `fixtures/live-run.json`, one real
run. Managed settings that allow only Anthropic's API refuse the mock, so a
factory runs `--live` and the offline probe prints REFUSED.

### `adapter`

`agent-hook-claude <tools.json> <manifest.json>` is what `codegen/hooks.nix`
registers for a profile's vendor-free hooks (`agents-frontend.md`). It turns
Claude's hook JSON into the neutral event, runs the frontend's dispatcher in
process and prints the folded result as Claude's output. A tool with no
vendor-free name reaches it as `other`, only where a hook names no tools: such
an event's entry has no matcher. It reads the calling agent's own transcript
tail for a shell call's `history` and a result's `context`; an unreadable one
gives none. Input it cannot read exits 1, which Claude shows and lets the call
go on.

| Claude event | Neutral event | Output |
|---|---|---|
| `SessionStart` | `sessionStart` | `additionalContext` |
| `PreToolUse` | `beforeTool` | `permissionDecision: deny` and its reason, or `additionalContext` |
| `PostToolUse` | `afterTool` | `additionalContext` |
| `SubagentStart` (no matcher) | `agentStart`, `agent_type` as the role | `additionalContext` |
| `UserPromptExpansion` (no matcher) | `promptExpansion`, `command_name` as the skill | `additionalContext` |

Only documented hook features: no `updatedInput` from any state hook (auto
mode refuses a rewritten call), and no field outside Claude's hooks docs.

### State hooks on Claude

The kernel's (`kernel/hooks.nix`, ADR 0016); what Claude gives them:

- **Binding.** `$XDG_STATE_HOME/state/bindings/<session_id>/<agent_id>` (the
  lead's `main`) holds the `run <id> <notes> <toplevel>` line `state init`
  prints. `PostToolUse` on `Bash` binds the caller when the command ran
  `state init`; on `Agent`, `tool_response.agentId` binds a spawned worker to
  its spawner's run. It fires at launch for a background spawn, after the
  hand-back for a foreground one, so a hand-back seen first is stashed in
  `handback-<agent_id>.json` and recorded at the bind.
- **Resolution.** A hook acts on the caller's bound run; only the lead falls
  back to its `cwd`, which for a subagent is its spawner's. A reply about a
  run starts `run <id>: `.
- **Deny.** `PreToolUse` on `Bash`: a `state` call that reads a run (not
  `init` or help) whose directory, the `cwd` or a `cd <dir>` before it, is in another git
  worktree than the bound run's is denied with `fix: cd <toplevel> && state
  ...`. Reading another run, `show`, `pending` or `brief` too, is that run's
  agent's job. A command the simple reader cannot follow passes.
- **Begin.** `SubagentStart` tells an `engineer` its run starts at the
  `state init` line in its prompt, and a worker role its `state brief`.
  `UserPromptExpansion` of a typed `/engineer` or `/10x-engineer`, and
  `PreToolUse` on `Skill` naming one, tell it to begin with `state`.

### Secret files

The wrapper exports a secret file's **path**. Where one is exported,
`withSecretFileGuard` adds `Read` deny rules over `/run/secrets` and
`/run/secrets.d`; the frontend's `secret-guard` covers the shell. **This is
protection against accidental reads, not a security boundary**: every
`qa-node` script must read the variable, so no filter over command text can
close it.
