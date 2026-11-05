# Reading the report

The report is a head (title, legend, `summary`, `index`) and sections. Each
index row is `slug|lines|headline`: read a section with `sed -n 'A,Bp'`.
Tables are `a|b|c` rows under one header, capped at 5 to 12 rows with
`+N more`; `none` means empty. Ask a researcher for capped rows.

## Units

- **Tokens** `input/cache read/cache write/output`, deduplicated by
  `message.id`. **Context** at a call is input + cache read + cache write;
  **peak context** its maximum over an agent's calls.
- **Effective** is what a call costs in input tokens: input x1, cache read
  x0.1, cache write x1.25, output x5. Tables rank by it. A cached 200k context
  costs less than a fresh 30k.
- `k`/`M` are thousands and millions, `m` minutes, `s` seconds; sizes in
  chars, or tokens as chars / 4. Session ids are the first 8 characters.
- **Wall** is wall clock; **work** is wall minus **waiting on the person**
  (an open `AskUserQuestion`, or a gap before a human prompt with no tool
  call running). Waiting is never a bottleneck. Parallel sessions and agents
  overlap: never add them up as machine time.

## Sections

- `sessions`, `agent-types`, `subagents`, `skills` (`attributionSkill`): cost
  by unit, costliest first.
- `startup`: an agent's first-call context, p50 and p90 by type, split into
  instructions, skill listing and remainder (tool schemas, base prompt, brief).
- `quality`: cost by the first `Quality:` and `Size:` lines in a brief; an
  agent with none takes the nearest one above it. `(none stated)` is older
  than the rule, not Balanced. An agent counts in its own row, so sessions do
  not add up. Per PR is the median over sessions of a mode's cost divided by
  the PRs it opened (`gh pr create` that did not fail).
- `loop-steps`: each top-level subagent and its children as one step,
  labelled by hand-tuned patterns over type, description and brief head; what
  matches nothing is `other`. Agent wall adds agents up.
- `cache-rewrites`, `cache-rewriters`: a call whose cache write is over half
  its context after a gap longer than the cache life (5 min for a subagent,
  1 h for the main agent), costed at the write alone, by what it waited on.
- `review-yield`, `review-agents`: findings per review pass and per inner
  review agent, parsed from `pragmatic-review`'s format; `unparsed` counts
  reports without the `N raised, M survived` line. Counts are before the
  orchestrator judged them. `run by main` is review text in the main agent.
- `after-handback`: human prompts after a session's first `gh pr ready`.
- `briefs`: brief and hand-back words by type and step; under 20 is a stall,
  an empty return or an agent still running. Review reports may run to 400.
- `parent-after-handback`: the parent's calls between a child ending and its
  next spawn. A re-read names a file the hand-back named, or is a `git diff`
  or `git show`; a re-verify is a check; spawned again is a spawn of the same
  step after its sibling ended.
- `handoffs`: hand-backs over 300 words and their tokens times the parent's
  later calls, an estimate; a `/tmp/....md` path counts as a notes file.
- `repeated-reads`: one exact path and range, or one read-only Bash command,
  read by two or more agents of a session.
- `largest-results`, `tool-times`, `bash-times`: tool results by size, and
  tool time from a call's response end to its result; a background call ends
  at its task notification.
- `reruns`: a check rerun with the same arguments when nothing, or only `.md`
  files, changed since. `chains`: a build, test or lint step run before
  `just check` or `nix flake check` with no edit between.
- `polling`: `sleep`, `until` and `while ... sleep` loops, and `gh pr checks`
  without `--watch`.
- `failures`: `is_error` results, `command not found` and failed background
  tasks, grouped by command and first error line with numbers masked.
- `compare` (with `--compare ISO`, paired with an earlier `--since`): medians
  before and after a date by session start. A side under n = 5 is
  `not enough data`. It is a lead, never a verdict: the loop changes under it.

## Blind spots

- Commands split on `&&`, `;` and `|` without parsing quotes, and group by
  tool and subcommand, so different filters share a row.
- Edits through `python -c`, a script, `shutil` or `os.rename` are unseen, so
  reruns after them are overstated. Reads through `find`, `xargs`, a loop or
  `$(...)` are unseen, so repeated reads are undercounted. File names match
  without their directory.
- A background call that never notified has no end: its gap counts as
  waiting. A session across a `--compare` date counts on its start's side.
- Cost per PR misses a PR opened in another session or by a script.
- Counts are leads. Whether a finding was a real bug, a fix regressed, CI
  failed for a reason a local check would catch, or a re-read repeated work
  needs a researcher reading the rows, and outcomes need `gh` on the PRs
  (reviews, CI runs before and after ready, reverts), looking past the window.

## Transcripts, for researchers

- Main agents: `~/.claude/projects/<encoded cwd>/<session>.jsonl` (names start
  with `-`: quote them). Subagents: `<session>/subagents/agent-<id>.jsonl`,
  with `agent-<id>.meta.json` holding `agentType`, `description`, `toolUseId`
  and `parentAgentId`.
- One JSON object per line. `assistant` lines carry `message.usage` and
  `tool_use` blocks, one line per block repeating the usage; `user` lines
  carry `tool_result` blocks and `toolUseResult`. A human prompt has
  `origin.kind == "human"`. A subagent's report is its `SubagentHandback`
  `input.message`; its brief is its first user line.
