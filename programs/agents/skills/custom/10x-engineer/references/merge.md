# Merge loop

One merge at a time. A wake only says where to look: re-read everything live.

## Read

```sh
gh pr view <n> --repo <owner>/<repo> \
  --json state,isDraft,baseRefName,headRefOid,mergeable,reviews
gh pr checks <n> --repo <owner>/<repo>
gh api repos/<owner>/<repo>/compare/<base>...<headRefOid> --jq .behind_by
gh api 'repos/<owner>/<repo>/commits/HEAD/check-runs?per_page=100' \
  --jq '[.total_count, ([.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out")] | length)]'
```

`gh pr checks` exits 0 when green and 8 while pending. Read the SHA first, so a
later push fails the merge instead of slipping past the check. The last command
gives `[all, failed]` checks on the default branch's head. `all` at 0 means CI
does not run on push, so the base is unknown: section 7 says how to treat it.

## Gates

Every one must hold for the SHA you read. Rulesets enforce the approval count
only: they do not require CI, and they keep an approval across later pushes.

| Gate | Holds when | Otherwise |
|---|---|---|
| Open | `state` is `OPEN`, `isDraft` false | Stop, re-read the ledger |
| Approved | the user's latest non-`COMMENTED` review is `APPROVED`, on this SHA or on one the ledger's merge-safe heads chain to it | Back to `review`: ask for approval |
| Green | `gh pr checks` exits 0 with at least one check, or the user's recorded answer accepts none | Pending: end the turn. Red or none: section 7 |
| Base | `failed` is 0, or this PR is the base fix | Held: section 7's base path, as for a red PR, then end the turn |
| Current | `behind_by` is 0 and `mergeable` is not `CONFLICTING` | Rebase |

Only the user's review counts, read from `reviews`, never a comment. A CI fix or
any other push after approval needs a new approval. An epic child skips the
Approved gate; a PR to `main` never does.

## Merge

```sh
gh pr merge <n> --repo <owner>/<repo> --squash --match-head-commit <sha>
```

`mergeable` may read `UNKNOWN`: read it once more before acting. Still
`UNKNOWN`: merge anyway, GitHub refuses a conflict. A refused merge: read again from the top. Refused twice: tell the user.

## Rebase

Through a fresh fixer in the task's worktree, in `references/brief.md`'s form,
counted against the 3-agent cap:

- `CLEAN`: add `<old head> -> <new head>` to the merge-safe heads and end the
  turn. On the green wake, merge with no new approval.
- `CONFLICT`: code changed. Back to `review`, and once green ask for a new
  approval, saying what changed. An epic child needs none.

## After each merge

GitHub sends no webhook when a base advance makes a PR conflict, so check it
yourself:

1. Confirm `state` is `MERGED`. Mark the task `merged`, notify.
2. `git -C <clone> worktree remove <path>`, then
   `git -C <clone> branch -D <branch>`, with `<clone>` as `references/brief.md`
   defines it.
3. After a base fix, merge the default branch into each live epic of that repo,
   never a rebase, since children branch from it:
   `gh api repos/<owner>/<repo>/merges -f base=epic/<name> -f head=<default>`.
   A 409 is a conflict: escalate it.
4. Read `mergeable` for each remaining open PR of the run in that repo. A
   `CONFLICTING` PR gets a rebase, and after a base fix so does each PR red on
   the base: in a free slot, else `queued` until one frees. A `running` task is
   left alone, since its worktree has a writer: the Current gate catches it. One
   merely behind rebases when its turn comes, so CI does not run for nothing.
5. Dispatch what the merge unblocked, then take the next approved PR.

## Review wakes

- `APPROVED`: this loop. Another merge in flight: it waits its turn.
- `CHANGES_REQUESTED` or a comment from the user: triage it like a hand-back.
  What it needs goes to a fresh fixer, back to `review` on green, with a new
  approval.
