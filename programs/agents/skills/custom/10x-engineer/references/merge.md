# Merge loop

One merge at a time. A wake only says where to look: re-read everything live.

## Read

```sh
gh pr view <n> --repo <owner>/<repo> \
  --json state,isDraft,baseRefName,headRefOid,mergeable,reviews
gh pr checks <n> --repo <owner>/<repo>
gh api repos/<owner>/<repo>/compare/<base>...<headRefOid> --jq .behind_by
gh api 'repos/<owner>/<repo>/commits/HEAD/check-runs?per_page=100' \
  --jq '[.check_runs[] | select(.conclusion == "failure")] | length'
```

`gh pr checks` exits 0 when green and 8 while pending. Read the SHA first, so a
later push fails the merge instead of slipping past the check. The last command
counts failed checks on the default branch's head.

## Gates

Every one must hold for the SHA you read. Rulesets enforce the approval count
only: they do not require CI, and they keep an approval across later pushes.

| Gate | Holds when | Otherwise |
|---|---|---|
| Open | `state` is `OPEN`, `isDraft` false | Stop, re-read the ledger |
| Approved | the user's latest review is `APPROVED`, on this SHA or on one the ledger's merge-safe heads chain to it | Back to `review`: ask for approval |
| Green | `gh pr checks` exits 0 with at least one check | Pending: end the turn. Red: section 7. None: ask the user |
| Base | the failed count is 0, or this PR is the base fix | Start the base fix if section 7 calls for one, then end the turn |
| Current | `behind_by` is 0 and `mergeable` is not `CONFLICTING` | Rebase |

Only the user's review counts, read from `reviews`, never a comment. A CI fix or
any other push after approval needs a new approval. An epic child skips the
Approved gate; a PR to `main` never does.

## Merge

```sh
gh pr merge <n> --repo <owner>/<repo> --squash --match-head-commit <sha>
```

`mergeable` may read `UNKNOWN`: merge anyway, GitHub refuses a conflict. A
refused merge: read again from the top. Refused twice: tell the user.

## Rebase

Through a fresh fixer in the task's worktree, in `references/brief.md`'s form:

- `CLEAN`: add `<old head> -> <new head>` to the merge-safe heads and end the
  turn. On the green wake, merge with no new approval.
- `CONFLICT`: code changed. Back to `review`, and ask for a new approval once
  green, saying what changed.

## After each merge

GitHub sends no webhook when a base advance makes a PR conflict, so check it
yourself:

1. Confirm `state` is `MERGED`. Mark the task `merged`, notify.
2. `git -C <clone> worktree remove <path>`, then
   `git -C <clone> branch -D <branch>`, with `<clone>` as `references/brief.md`
   defines it.
3. Read `mergeable` for each remaining open PR of the run in that repo. A
   `CONFLICTING` PR rebases now, and after a base fix so does each PR red on the
   base. One merely behind rebases when its turn comes, so CI does not run for
   nothing.
4. Dispatch what the merge unblocked, then take the next approved PR.

## Review wakes

- `APPROVED`: this loop. Another merge in flight: it waits its turn.
- `CHANGES_REQUESTED` or a comment from the user: triage it like a hand-back.
  What it needs goes to a fresh fixer, back to `review` on green, with a new
  approval.
