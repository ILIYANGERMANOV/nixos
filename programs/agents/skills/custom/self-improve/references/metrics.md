# Metrics

What the analyzer measures, how, and where it is blind. Hand the layout and
rules below to any subagent that digs into the raw transcripts, so its numbers
agree with the report.

## Transcript layout

- Main agents: `~/.claude/projects/<encoded cwd>/<session>.jsonl`. Directory
  names start with `-`, so use Python's `pathlib` or quote them.
- Subagents: `<session>/subagents/agent-<id>.jsonl`, with
  `agent-<id>.meta.json` holding `agentType`, `description`, `toolUseId` (the
  spawning call) and `spawnDepth`.
- One JSON object per line, with `type` and `timestamp`. `assistant` lines
  carry `message.usage` and `tool_use` blocks in `message.content`; `user`
  lines carry `tool_result` blocks keyed by `tool_use_id`, plus a
  `toolUseResult` (Bash: `stdout`, `stderr`, `interrupted`, `backgroundTaskId`).
- A person's prompt has `origin.kind == "human"`; a slash command appears as
  `<command-name>/engineer</command-name>` in it.

## Measurement rules

- **Tokens.** One response spans several lines, one per content block, each
  repeating the same usage: deduplicate by `message.id` (else `requestId`).
  Usage splits into input, cache read, cache write and output. Context at a
  call is input + cache read + cache write; **peak context** is its maximum
  over an agent's calls. `attributionSkill` names the skill a call ran under.
- **Wall time of a tool call.** No duration field exists: it is the
  `tool_use` timestamp to the `tool_result` timestamp. A background call
  (`backgroundTaskId` or `isAsync` in `toolUseResult`) ends at the first
  `<task-notification>` naming its `<tool-use-id>`, delivered as a
  `queue-operation` line or a user line; its `<status>` and summary give
  failure and exit code.
- **Waiting on the person.** The gap before each human prompt, plus the time
  `AskUserQuestion` calls stayed open. Work time is wall clock minus that.
- **Failures.** `is_error` results (non-zero exit, blocked or invalid calls),
  results containing `command not found`, and failed background
  notifications, grouped by command and their first error line with numbers
  and hashes masked.
- **Redundant check.** A check rerun with the same arguments when no agent of
  the session edited anything since, or edited only `.md` files. Edits are
  `Edit`, `Write`, `NotebookEdit`, and Bash `sed -i`, `tee`, `cat >` and
  branch-changing git commands.
- **Chain.** A build, test or lint step run in front of `just check` or
  `nix flake check` - in the same command or earlier with no edit between -
  which the full check already runs.
- **Sleep and poll loops.** Bash calls with `sleep N`, `until` or a `while`
  with `sleep`, and `gh pr checks` without `--watch`.

## Blind spots

- Commands are split on `&&`, `;` and `|` without parsing quotes, so a quoted
  separator can mislabel one call. Grouping is by the leading tool and
  subcommand (`nix run .#test`), so different filters share a row.
- Wall clock per session overlaps across parallel sessions; do not add
  sessions up to claim machine time.
- A gap before a human prompt counts as waiting even when background work was
  still running in it.
- The report caps every table; ask a subagent for the omitted rows.
