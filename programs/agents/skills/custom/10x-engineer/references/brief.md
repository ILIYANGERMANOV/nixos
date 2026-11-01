# Worktree, brief and spawn prompt

## Worktree

`<clone>` is `~/repos/<repo>`, or `<this worktree>` for the repo this session
runs in: isolation checks refuse git in its main checkout.

New work:

```sh
git -C <clone> fetch origin
git -C <clone> worktree add -b <branch> ~/.10x/<run>/worktrees/<task> origin/<base>
```

A named PR:

```sh
git -C <clone> fetch origin <branch>
git -C <clone> worktree add --track -b <branch> ~/.10x/<run>/worktrees/<task> origin/<branch>
```

Keep the worktree until the PR merges, since fixers use it too. A retry reuses
it. A named PR's branch that exists locally: reuse the worktree holding it
(`git -C <clone> worktree list`), or `worktree add <path> <branch>` if none does.

## Brief

`~/.10x/<run>/briefs/<task>.md`, with every field. No pasted research: paths.

```markdown
# <task>

Mode: delegated.
Quality: <mode>, then `, Trivial` for a Trivial task

## The user's words

<verbatim, only what concerns this task. Never widen them.>

## Plan

<decided plan: goal, approach, decisions, shared interfaces from the pre-flight>

## Acceptance criteria

- <input to observable outcome>

Security-sensitive: <topics, or none>

## Where

- Repo: <owner>/<repo>
- Base branch: <main or epic/<name>>
- Worktree: <absolute path>; every command uses it, by `git -C` or an absolute
  path, and every `gh` command by `--repo <owner>/<repo>`. Never touch `~/repos/<repo>`.
- Repo rules: read the worktree's `CLAUDE.md` or `AGENTS.md` and follow them.
- Issues: <#n each, closed by `Closes #n` in the PR body, or none>
- Existing PR: <URL and the step to start from, or none>
- Report file: ~/.10x/<run>/reports/<task>.md
- Requirements file: ~/.10x/<run>/reports/<task>-requirements.md

## Checks

<exact targeted commands, the repo's lint and format included>

## Out of scope

- <item>

## Notes

<research note paths; on a retry, why the last try failed>
```

## Spawn prompt

```text
<the data line from SKILL.md's Rules>
Quality: <the task's>. Invoke `engineer`. You are delegated: your brief is <path>. Read it first and
follow the skill's `## Delegated` section.
```

## Fixer prompt

For CI failures, requested changes and rebases, a fresh background
`subagent_type: fixer` agent:

```text
<the data line from SKILL.md's Rules>
Quality: <the task's>. Worktree: <path>, use it for every command. PR: <URL>, base <base>. Fix: <the failing
check and its log, the review comments, or the rebase>. Run <targeted checks>, commit, push with `git push -u origin
HEAD`. Hand back in about 250 words, never over 300, starting with exactly one
of `READY <PR URL>`, `NEEDS_DECISION <question>`, `BLOCKED <reason>` or
`FAILED <reason>`.
```

A rebase fixer gets the PR's live `headRefOid` as `<old head>`, and in place of
the push line:

```sh
git rebase --abort             # only if a dead fixer left one in progress
git fetch origin <branch> <base>
git status --porcelain         # must print nothing
git rev-list <old head>..HEAD  # must print nothing
git reset --hard <old head>
git rebase origin/<base>
git push --force-with-lease=<branch>:<old head> origin HEAD
```

A check that prints means another worker's unpushed work: never reset it, hand
back `NEEDS_DECISION`. A refused push means the head moved: hand back `BLOCKED`.
You decide what the rebase changed, through `references/merge.md`'s Rebase.
