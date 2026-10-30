# Metrics

What the analyzer measures, how, and where it is blind. Hand the layout and
rules below to any subagent that digs into the raw transcripts, so its numbers
agree with the report.

## Transcript layout

- Main agents: `~/.claude/projects/<encoded cwd>/<session>.jsonl`. Directory
  names start with `-`, so use Python's `pathlib` or quote them.
- Subagents: `<session>/subagents/agent-<id>.jsonl`, with
  `agent-<id>.meta.json` holding `agentType`, `description`, `toolUseId` (the
  spawning call), `spawnDepth` and `parentAgentId` (the spawning subagent, absent
  when the main agent spawned it).
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
- **Waiting on the person.** The time the main agent's `AskUserQuestion`
  stayed open (a subagent cannot ask), plus each gap before a human prompt in
  which no tool call of any agent (background ones included) was running;
  overlaps count once. Work time is wall clock
  minus that. Waiting is never a bottleneck, so `AskUserQuestion` is left out
  of the tool-time ranking.
- **Failures.** `is_error` results (non-zero exit, blocked or invalid calls),
  results containing `command not found`, and failed background
  notifications, grouped by command and their first error line with numbers
  and hashes masked.
- **Redundant check.** A check rerun with the same arguments when no agent of
  the session edited anything since, or edited only `.md` files. Edits are
  `Edit`, `Write`, `NotebookEdit`, and Bash `sed -i`, `tee`, `cat >`,
  branch-changing git commands and Python heredocs that write a file.
- **Chain.** A build, test or lint step run in front of `just check` or
  `nix flake check` - in the same command or earlier with no edit between -
  which the full check already runs.
- **Sleep and poll loops.** Bash calls with `sleep N`, `until` or a `while`
  with `sleep`, and `gh pr checks` without `--watch`.

## Quality signals

The report puts yield beside cost, and only the quality review turns it into a
judgment. It stays offline: everything from `gh` is the subagent's.

- **Final report.** A subagent's report is the `input.message` of its
  `SubagentHandback` tool call, not assistant text; the analyzer falls back to
  the last text. The brief is the subagent's first user line.
- **Loop steps.** Each top-level subagent gets one step from its description
  and the head of its brief; its children count under the same step. A review
  is a brief that invokes `pragmatic-review`, at any depth, so a review under an
  orchestrator subagent is a review with its own children: `--fixes`, "pass 2",
  "re-review" or "second" make it the second pass, "final" in the description
  `/final-review`. Agent wall adds agents up, so parallel agents overlap.
- **Review yield.** Parsed from the report format `pragmatic-review` fixes:
  the verdict's `N raised, M survived`, table rows `| n | Major |`, and
  `✅ Met`, `❌ Not met`, `⚠️ Unverified` lines. A report without the arithmetic
  counts as unparsed, so format drift shows, and its table rows still count.
  Inner agents are read from their
  `severity major|minor|nit` and `verdict met|not met|unverified` lines, typed
  by description. `run by main` is a text of the main agent holding the
  arithmetic or a table row, with no tokens to attribute; a report it merely
  relayed lands there too.
- **After hand-back.** Human prompts after the first `gh pr ready` of any agent
  of the session, split into slash commands and free text.

`gh` recipes, for a PR `N` on head branch `H` in `O/R`:

```
gh api "repos/O/R/actions/runs?branch=H&per_page=100" --jq '.workflow_runs[] | [.head_sha, .conclusion, .created_at] | @tsv'
gh api --paginate repos/O/R/issues/N/timeline --jq '.[] | select(.event == "ready_for_review") | .created_at'
gh pr view N --repo O/R --json reviews,comments,body,mergedAt,additions,deletions
gh pr list --repo O/R --state merged --search 'revert in:title' --json number,title
```

The first two split CI failures into before and after ready. `/qa` verdicts are
the `**Verdict:**` line in the PR body's `## QA`, and a feedback log its
`Feedback log` section. Only a commit stat, never an edit count, shows what a
refactor did: agents edit through Bash.

Outcomes land after a session while the window starts at the last run, so look
past it for follow-ups and reverts of recently merged PRs.

## Communication signals

The Agent communication section holds leads for the communication review.

- **Brief and hand-back size**: words per agent type and step, how many
  hand-backs exceed 300 words, and how many fall under 20, which is a stall, an
  empty return or an agent still running. Review reports may run to about 400.
- **After a hand-back**: the parent's calls from the moment a child ended to
  its next spawn, each attributed to the child that ended last. A re-read names
  a file the hand-back named, or is a `git diff` or `git show`. A re-verify is
  a check.
- **Spawned again**: a spawn with the same step as the sibling before it, begun
  after that sibling ended. Fan-out in parallel does not count; sequential
  implementers do.
- **Large hand-backs**: chars over the limit, and their tokens (chars / 4)
  times the parent's later tool calls, as an estimate of what carrying them
  cost. A `/tmp/....md` path in a hand-back counts as a notes file.
- **Follow-ups**: `SendMessage` calls.
- **Repeated work**: identical reads (`Read` of one path and range, or the same
  read-only Bash command) by two or more agents of a session.
- **Splits**: implementers reading a file name an earlier research agent read.

## What only reading can settle

The analyzer counts; these need a subagent reading the rows, and hand-tuned
labels mean its counts are a starting point, not a verdict.

- Whether a finding was a true positive, a real bug or a rule nit, and whether
  it stayed fixed.
- Whether a fix or a refactor introduced a regression: compare a second-pass
  row with the fix diff.
- Why CI failed, and whether a local check would have caught it: job logs.
- What a prompt after hand-back meant: a bug, a question or new scope.
- Follow-up fix PRs: a title regex misses them, so read the PRs by file overlap.
- Whether a re-read repeated work or verified it, and whether a spawned-again
  agent was a retry, a thin hand-back or the next slice.
- What a brief lacked: a follow-up message or a second spawn only hints at it.
- Why a tool goes unused, and what an `Unverified` verdict needed.

## Blind spots

- Commands are split on `&&`, `;` and `|` without parsing quotes, so a quoted
  separator can mislabel one call. Grouping is by the leading tool and
  subcommand (`nix run .#test`), so different filters share a row.
- Wall clock per session overlaps across parallel sessions; do not add
  sessions up to claim machine time.
- A background call that never sent a notification has no end, so a gap it
  overlapped counts as waiting.
- The report caps every table; ask a subagent for the omitted rows.
- Step labels rest on hand-tuned patterns over free-form descriptions: an agent
  doing two steps counts once, and whatever matches nothing lands in `other`.
  Inner review agents the main agent ran directly land in `other` too.
- A Python edit outside a heredoc (`python -c`, a script file) is not seen as
  an edit, so the reruns after it are overstated. An opaque script's writes
  stay invisible.
- File names are matched without their directory, so two files of one name
  count as one. A repeated read compares exact paths and commands, so one file
  read from two worktrees does not count.
