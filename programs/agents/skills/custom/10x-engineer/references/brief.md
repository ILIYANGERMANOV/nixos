# Worktree, brief and spawn prompt

## Worktree

`<clone>` is `~/repos/<repo>`, or `<this worktree>` for the repo this session
runs in: isolation checks refuse git in its main checkout.

New work:

```sh
git -C <clone> fetch origin
git -C <clone> worktree add -b <branch> ~/.10x/<run>/worktrees/<task> origin/<base>
```

A named or retried PR:

```sh
git -C <clone> fetch origin <branch>
git -C <clone> worktree add --track -b <branch> ~/.10x/<run>/worktrees/<task> origin/<branch>
```

Keep the worktree until the PR merges, since fixers use it too.

## Brief

`~/.10x/<run>/briefs/<task>.md`, with every field. No pasted research: paths.

```markdown
# <task>

Mode: delegated.

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
  path. Never touch `~/repos/<repo>`.
- Existing PR: <URL and the step to start from, or none>
- Report file: ~/.10x/<run>/reports/<task>.md

## Checks

<exact targeted commands, the repo's lint and format included>

## Out of scope

- <item>

## Notes

<research note paths; on a retry, why the last try failed>
```

## Spawn prompt

```text
Invoke `engineer`. You are delegated: your brief is <path>. Read it first and
follow the skill's `## Delegated` section.
```

## Fixer prompt

For CI failures, requested changes and rebases, a fresh background subagent:

```text
Invoke `engineering` first. Worktree: <path>, use it for every command. PR:
<URL>, base <base>. Fix: <the failing check and its log, the review comments,
or the rebase>. Run <targeted checks>, commit, push with `git push -u origin
HEAD`. After a rebase push with `git push --force-with-lease origin HEAD`.
Hand back in about 250 words, never over 300, starting with exactly one of
`READY <PR URL>`, `NEEDS_DECISION <question>`, `BLOCKED <reason>` or
`FAILED <reason>`, plus the new head SHA.
```

A rebase fixer also runs `git range-diff <old head>...HEAD` and reports `CLEAN`
only when `git rebase` stopped on no conflict and it added no commit, otherwise
`CONFLICT` with what changed.
